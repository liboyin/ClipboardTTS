import Foundation

/// Streams speech audio for one request at a time and publishes request state to the menu bar.
///
/// Marked `@unchecked Sendable` because the `URLSessionDataDelegate` conformance requires
/// `Sendable` and URLSession invokes delegate methods on its own queue. Four confinement rules
/// keep that sound, and concurrent delegate entry is covered by `TTSNetworkManagerConcurrencyTests`:
/// - Mutable request, settings, and metadata state (`activeRequest`, `requestGeneration`,
///   `baseURL`, `apiKey`, `model`, `voice`, `selectedMetadataProvider`, the metadata request
///   records, and the request-state publication flag) is read and written only under `stateQueue`.
/// - The `@Published` properties, `isPublishingMetadata`, `migrationFailureMessage`, and the queued
///   request-state publications are written only on the main queue (every write path dispatches or
///   already runs there); SwiftUI observes them on main. Construction is the one exception: the initializer assigns
///   `migrationFailureMessage`, and `lastError` when startup could not secure or read a saved key,
///   on whichever thread builds the manager and before it is shared.
/// - A recursive callback-authority lock spans delivery authorization through the complete handler
///   call and generation revocation; it is never the request-state lock, so direct re-entrant stops work.
/// - A path that needs both locks acquires callback authority before `stateQueue`; fatal Gemini
///   parsing advances its generation under `stateQueue` before waiting at callback authority.
/// `session` and `sessionInvalidated` are assigned once during init, before the manager is shared.
final class TTSNetworkManager: NSObject, ObservableObject, URLSessionDataDelegate, @unchecked Sendable {
    @Published var isStreaming = false
    /// A short, sanitized explanation of the most recent speech-request failure.
    @Published private(set) var lastError: String?
    /// The model and voice choices currently offered, each naming the provider that published it.
    @Published var modelSuggestions = ProviderSuggestions.unpublished
    @Published var voiceSuggestions = ProviderSuggestions.unpublished

    private(set) var baseURL: String
    private var apiKey: String
    private var model: String
    private var voice: String

    var session: URLSession!
    /// Session-lifecycle and request-body seams used by production setup and focused tests.
    private let sessionInvalidated: ((URLSession) -> Void)?
    let requestBodyEncoder: (Data) throws -> Data
    /// The two points on the request-state path whose invariant is about what may interleave there.
    /// Production does nothing at either; both exist because such an invariant can only be stated
    /// from inside the window it protects.
    ///
    /// `revocationTransaction` runs inside the transaction a conditional revocation opens, after it
    /// has read ownership and before it releases it: nothing may land between those two steps and
    /// leave the revocation advancing a generation nothing owns any more. `retryInstallation` runs
    /// after a retry's task is created and before that retry owns the pipeline, which is the window
    /// in which the attempt it continues has ended and it has not yet begun.
    let requestObservers: (revocationTransaction: @Sendable () -> Void, retryInstallation: @Sendable () -> Void)
    /// Serializes active-request state; client callbacks are captured here but always invoked after leaving this queue.
    let stateQueue = DispatchQueue(label: "com.clipboardtts.ttsnetworkmanager")
    /// Delivers request-owned PCM in the same order that `stateQueue` accepts delegate callbacks.
    ///
    /// Keeping this separate from `stateQueue` lets a handler synchronously stop or replace its
    /// stream without deadlocking the request-state lock.
    let audioDeliveryQueue: DispatchQueue
    /// Serializes generation revocation with delivery authorization and the complete client
    /// callback. It is recursive so a handler can synchronously stop or replace its own stream.
    let callbackAuthority: CallbackAuthorityLocking
    var activeRequest: ActiveRequestContext?
    var requestGeneration: UInt64 = 0
    private var isPublishingRequestState = false
    /// Request-state publications requested while another was being published, applied in order
    /// once it finishes. Main-queue confined, like the `@Published` properties it updates.
    private var queuedRequestStatePublications: [@Sendable () -> Void] = []
    /// The legacy-key migration warning this manager last published, retained so a later recovery
    /// can withdraw or replace exactly that message rather than whatever `lastError` holds by then.
    private var migrationFailureMessage: String?
    private(set) var selectedMetadataProvider: APIKeyProvider
    var metadataGeneration: UInt64 = 0
    var nextMetadataRequestIdentifier: UInt64 = 0
    var modelMetadataRequest: MetadataRequest?
    var voiceMetadataRequest: MetadataRequest?
    var isPublishingMetadata = false

    /// Returns the active task for debug-only delegate-ordering tests.
    #if DEBUG
    var activeTaskForTesting: URLSessionDataTask? { stateQueue.sync { activeRequest?.task } }
    #endif

    /// The values used to create one request, captured before the task is resumed.
    struct RequestSettings {
        let baseURL: String
        let apiKey: String
        let model: String
        let voice: String
        let provider: APIKeyProvider
    }

    /// State that belongs exclusively to the active URL session task and is guarded by `stateQueue`.
    struct ActiveRequestContext {
        let task: URLSessionDataTask
        let taskIdentifier: Int
        let requestGeneration: UInt64
        let provider: APIKeyProvider
        /// The request this attempt sent, retained so its permitted retry replays exactly it.
        let request: URLRequest
        /// Receives this request's PCM and, behind all of it, the one terminal event it delivers.
        let client: SpeechStreamClient
        /// Whether this attempt is itself the retry, which is what bounds recovery to one extra try.
        let isRetryAttempt: Bool
        var isErrorResponse = false
        var responseStatusCode: Int?
        /// Whether this response declared a body that cannot be read as PCM, which is a separate
        /// reason to discard it from the non-2xx status `isErrorResponse` records: a success this
        /// request must not play still succeeded, and says so with its own message.
        var refusedResponseFormat = false
        var geminiEventParser = GeminiSSEEventParser()
        var geminiIncompletePCM = Data()
        var hasGeminiStreamFailure = false
        /// The most recent `finishReason` a Gemini candidate declared, retained because only an
        /// explicit non-`STOP` reason distinguishes a provider-truncated stream from a normal end.
        var geminiDeclaredFinishReason: String?
        var providerAudioByteCount = 0
        /// Why a redirect this request was asked to follow was refused, if one was.
        /// `TTSNetworkManager+Redirects` owns both the decision and what it publishes.
        var refusedRedirect: RefusedRedirect?
    }

    /// Creates a manager, optionally observing the lifecycle of its underlying URL session, the
    /// request-state transaction a conditional revocation opens, and a retry's installation.
    init(configuration: URLSessionConfiguration? = nil,
         sessionCreated: ((URLSession) -> Void)? = nil,
         sessionInvalidated: ((URLSession) -> Void)? = nil,
         secretStore: SecretStoring = KeychainSecretStore(),
         defaults: UserDefaults,
         requestBodyEncoder: @escaping (Data) throws -> Data = { $0 },
         audioDeliveryQueue: DispatchQueue = DispatchQueue(label: "com.clipboardtts.ttsaudiodelivery"),
         callbackAuthority: CallbackAuthorityLocking = RecursiveCallbackAuthority(),
         revocationTransactionObserver: @escaping @Sendable () -> Void = {},
         retryInstallationObserver: @escaping @Sendable () -> Void = {}) {
        let persistedProvider = defaults.string(forKey: SettingsKeys.ttsProvider) ?? "OpenAI"
        let provider = APIKeyProvider(selectedProvider: persistedProvider)
        self.selectedMetadataProvider = provider
        let secretStartupState = APIKeyStartupState.load(
            selectedProvider: provider.settingsValue, secretStore: secretStore, defaults: defaults
        )
        switch provider {
        case .openAI:
            self.baseURL = "https://api.openai.com/v1/audio/speech"
            self.apiKey = secretStartupState.apiKey
            self.model = defaults.string(forKey: SettingsKeys.openAIModel) ?? "tts-1"
            self.voice = defaults.string(forKey: SettingsKeys.openAIVoice) ?? "alloy"
        case .gemini:
            self.baseURL = "https://generativelanguage.googleapis.com/v1beta"
            self.apiKey = secretStartupState.apiKey
            self.model = defaults.string(forKey: SettingsKeys.geminiModel) ?? "gemini-3.1-flash-tts-preview"
            self.voice = defaults.string(forKey: SettingsKeys.geminiVoice) ?? "Aoede"
        case .custom:
            self.baseURL = defaults.string(forKey: SettingsKeys.apiBaseURL) ?? "https://api.openai.com/v1/audio/speech"
            self.apiKey = secretStartupState.apiKey
            self.model = defaults.string(forKey: SettingsKeys.customModel) ?? ""
            self.voice = defaults.string(forKey: SettingsKeys.customVoice) ?? ""
        }
        self.requestBodyEncoder = requestBodyEncoder
        self.requestObservers = (revocationTransaction: revocationTransactionObserver,
                                 retryInstallation: retryInstallationObserver)
        self.sessionInvalidated = sessionInvalidated
        self.audioDeliveryQueue = audioDeliveryQueue
        self.callbackAuthority = callbackAuthority

        super.init()
        self.session = URLSession(configuration: configuration ?? Self.productionSessionConfiguration(), delegate: self, delegateQueue: nil)
        sessionCreated?(self.session)
        if let errorMessage = secretStartupState.errorMessage { self.lastError = errorMessage }
        // Startup collapses its migration failures into the first provider's guidance, so the same
        // provider's message identifies the warning published above. A key that could not be read
        // produces a different message, which securing a legacy key does not resolve.
        self.migrationFailureMessage = APIKeyMigrationService.pendingProviders(defaults: defaults)
            .first
            .map(APIKeyMigrationService.failureMessage(for:))
    }

    /// Updates the settings used by future TTS requests and invalidates metadata from a previous provider or endpoint.
    ///
    /// The caller's string is normalized before it enters request or metadata state, so endpoint
    /// text cannot select a protocol and every stored identity has a matching provider surface.
    func updateSettings(baseURL: String,
                        apiKey: String,
                        model: String,
                        voice: String,
                        selectedProvider: String) {
        let provider = APIKeyProvider(selectedProvider: selectedProvider)
        let invalidatedGeneration: UInt64? = stateQueue.sync {
            let metadataScopeChanged = self.baseURL != baseURL || self.selectedMetadataProvider != provider
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.voice = voice
            self.selectedMetadataProvider = provider

            guard metadataScopeChanged else { return nil }

            metadataGeneration &+= 1
            modelMetadataRequest?.task?.cancel()
            modelMetadataRequest = nil
            voiceMetadataRequest = nil
            return metadataGeneration
        }
        if let invalidatedGeneration {
            clearMetadataLists(for: invalidatedGeneration)
        }
    }

    /// Returns the token identifying which logical request currently owns the pipeline.
    ///
    /// It advances only when a request starts, is replaced, or is stopped, so a caller that
    /// captured it earlier can tell that somebody else claimed or released the pipeline in between
    /// — including while a finished request's accepted audio has not reached the player yet, when
    /// neither `isStreaming` nor `hasAudio` reports the pipeline as busy. A request's own automatic
    /// retry inherits this token rather than advancing it, because recovering from a transient
    /// provider failure is not somebody else claiming the pipeline; keep it that way, or every
    /// waiting menu action would go stale on a retry the user never asked for.
    func currentRequestGeneration() -> UInt64 {
        stateQueue.sync { requestGeneration }
    }

    /// Returns whether the manager's future-request settings belong to the supplied persisted provider.
    func isCurrentProvider(_ provider: APIKeyProvider) -> Bool {
        stateQueue.sync {
            selectedMetadataProvider == provider
        }
    }

    /// Returns the model that future requests will use.
    ///
    /// Deliberately reads the model alone: the voice-catalog path is the only caller, and the one
    /// catalog that depends on the model depends on nothing else. Handing it an aggregate would deliver the saved API key,
    /// endpoint, and provider identity to a metadata-only path that would discard all three, so a
    /// credential must not be added back here.
    func currentModel() -> String {
        stateQueue.sync { model }
    }

    /// Captures the immutable settings one request attempt owns from start to finish.
    func requestSettingsSnapshot() -> RequestSettings {
        stateQueue.sync {
            RequestSettings(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                voice: voice,
                provider: selectedMetadataProvider
            )
        }
    }

    /// Publishes a request failure on the main queue and marks the request as finished.
    func publishFailure(_ message: String, requestGeneration: UInt64? = nil) {
        publishRequestState { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.lastError = message
                self.isStreaming = false
            }
        }
    }

    /// Clears a failure message only when it belongs to the latest request attempt.
    func clearLastError(requestGeneration: UInt64? = nil) {
        publishRequestState { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.lastError = nil
            }
        }
    }

    /// Republishes or withdraws the warning about a legacy key that could not be secured.
    ///
    /// Settings calls this after the user retries that migration: passing the provider still
    /// pending keeps the menu bar naming a key that really is unsecured, and passing `nil`
    /// withdraws the warning once every one of them is secured. Only the message this manager
    /// itself published for migration is replaced: a request that published or cleared `lastError`
    /// since then owns that line, and what it says — including saying nothing — is not something
    /// securing a key changes. An unresolved migration therefore stays visible in Settings, which
    /// is where its recovery is.
    func updateMigrationFailureWarning(for provider: APIKeyProvider?) {
        let message = provider.map(APIKeyMigrationService.failureMessage(for:))
        publishRequestState { [weak self] in
            guard let self else { return }
            let publishedWarning = self.migrationFailureMessage
            self.migrationFailureMessage = message
            guard self.lastError == publishedWarning else { return }
            self.withRequestStatePublication {
                self.lastError = message
            }
        }
    }

    /// Withdraws startup's guidance that a provider's saved key could not be read, once Settings has
    /// read it. Like `updateMigrationFailureWarning`, it replaces only that exact message: a request
    /// that published or cleared `lastError` since startup owns that line.
    func withdrawKeyReadFailure(for provider: APIKeyProvider) {
        let message = APIKeyStartupState.readFailureMessage(for: provider)
        publishRequestState { [weak self] in
            guard let self, self.lastError == message else { return }
            self.withRequestStatePublication { self.lastError = nil }
        }
    }

    /// Publishes the request lifecycle state on the main queue.
    func setStreaming(_ isStreaming: Bool, requestGeneration: UInt64? = nil) {
        publishRequestState { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.isStreaming = isStreaming
            }
        }
    }

    /// Returns whether a completion still belongs to the latest stream generation.
    func isCurrentRequestGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return stateQueue.sync { requestGeneration == generation }
    }

    /// Defers request starts triggered by synchronous `@Published` observer re-entrancy.
    func deferRequestStartIfPublishingState(_ action: @escaping @Sendable () -> Void) -> Bool {
        let isPublishing = stateQueue.sync { isPublishingRequestState }
        guard isPublishing else { return false }
        DispatchQueue.main.async(execute: action)
        return true
    }

    /// Applies a request-state publication on the main queue, or queues it behind the one in progress.
    /// `@Published` notifies observers before storing, so a publication an observer requests there
    /// would be stored over by the outer value. A queued one is evaluated only when the outer
    /// publication applies it, so its checks judge the state it replaces.
    private func publishRequestState(_ update: @escaping @Sendable () -> Void) {
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { [weak self] in self?.publishRequestState(update) }
        }
        if stateQueue.sync(execute: { isPublishingRequestState }) {
            queuedRequestStatePublications.append(update)
        } else {
            update()
        }
    }

    /// Marks a `@Published` mutation so re-entrant observers cannot start a request or publish
    /// request state mid-update, then applies, in order, any publication they queued. It never
    /// nests: `publishRequestState` runs an update only while no publication is in progress.
    private func withRequestStatePublication(_ update: () -> Void) {
        stateQueue.sync { isPublishingRequestState = true }
        update()
        stateQueue.sync { isPublishingRequestState = false }
        while !queuedRequestStatePublications.isEmpty {
            queuedRequestStatePublications.removeFirst()()
        }
    }

    /// Records what a response says about itself before any of its body arrives.
    ///
    /// A refused format is allowed and then dropped rather than cancelled here, which is how a
    /// non-2xx response is already handled. Cancelling would end the task with a URL error, and
    /// this request would then have two reasons to fail — the one it chose and the cancellation it
    /// caused — where the second is the app's own doing and describes nothing the user can act on.
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        var shouldAllow = false
        stateQueue.sync {
            if var context = activeRequest, dataTask.taskIdentifier == context.taskIdentifier {
                shouldAllow = true
                if let httpResponse = response as? HTTPURLResponse {
                    context.responseStatusCode = httpResponse.statusCode
                    if !(200...299).contains(httpResponse.statusCode) {
                        context.isErrorResponse = true
                    } else if declaresUnplayableBody(httpResponse, for: context.provider) {
                        context.refusedResponseFormat = true
                    }
                }
                activeRequest = context
            }
        }
        completionHandler(shouldAllow ? .allow : .cancel)
    }

    /// Returns whether a successful response declares a body this request cannot read as PCM.
    ///
    /// Gemini is exempt because its body is a Server-Sent Event stream rather than the audio
    /// itself: `text/event-stream` is the correct declaration there, and what has to be checked is
    /// each event's own inline payload, which `TTSNetworkManager+GeminiStreaming` does.
    private func declaresUnplayableBody(_ response: HTTPURLResponse, for provider: APIKeyProvider) -> Bool {
        guard provider != .gemini else { return false }
        return !SpeechResponseFormatPolicy.permitsPCMBody(
            declaredContentType: response.value(forHTTPHeaderField: "Content-Type")
        )
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        sessionInvalidated?(session)
    }
}
