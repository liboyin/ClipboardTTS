import Foundation

/// Streams speech audio for one request at a time and publishes request state to the menu bar.
///
/// Marked `@unchecked Sendable` because the `URLSessionDataDelegate` conformance requires
/// `Sendable` and URLSession invokes delegate methods on its own queue. Three confinement rules
/// keep that sound, and concurrent delegate entry is covered by `TTSNetworkManagerConcurrencyTests`:
/// - Mutable request, settings, and metadata state (`activeRequest`, `requestGeneration`,
///   `baseURL`, `apiKey`, `model`, `voice`, `selectedMetadataProvider`, the metadata request
///   records, and the publication-depth counter) is read and written only under `stateQueue`.
/// - The `@Published` properties and `isPublishingMetadata` are written only on the main queue
///   (every write path dispatches or already runs there) and are observed by SwiftUI on main.
/// - A recursive callback-authority lock spans delivery authorization through the complete handler
///   call and generation revocation; it is never the request-state lock, so direct re-entrant stops work.
/// - A path that needs both locks acquires callback authority before `stateQueue`; fatal Gemini
///   parsing advances its generation under `stateQueue` before waiting at callback authority.
/// `session` and `sessionInvalidated` are assigned once during init, before the manager is shared.
final class TTSNetworkManager: NSObject, ObservableObject, URLSessionDataDelegate, @unchecked Sendable {
    @Published var isStreaming = false
    /// A short, sanitized explanation of the most recent speech-request failure.
    @Published private(set) var lastError: String?
    @Published var availableModels: [String] = []
    @Published var availableVoices: [String] = []

    private(set) var baseURL: String
    private var apiKey: String
    private var model: String
    private var voice: String

    var session: URLSession!
    /// Session-lifecycle and request-body seams used by production setup and focused tests.
    private let sessionInvalidated: ((URLSession) -> Void)?
    let requestBodyEncoder: (Data) throws -> Data
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
    private var requestStatePublicationDepth = 0
    private(set) var selectedMetadataProvider: String
    var metadataGeneration: UInt64 = 0
    var nextMetadataRequestIdentifier: UInt64 = 0
    var modelMetadataRequest: MetadataRequest?
    var voiceMetadataRequest: MetadataRequest?
    var isPublishingMetadata = false

    /// Returns the active task for debug-only delegate-ordering tests.
    #if DEBUG
    var activeTaskForTesting: URLSessionDataTask? { stateQueue.sync { activeRequest?.task } }
    #endif

    enum ProviderKind: Equatable {
        case openAICompatible
        case gemini
        case custom

        init(baseURL: String, selectedProvider: String) {
            if selectedProvider == "Custom" {
                self = .custom
            } else {
                self = baseURL.contains("generativelanguage.googleapis.com") ? .gemini : .openAICompatible
            }
        }
    }

    /// The values used to create one request, captured before the task is resumed.
    struct RequestSettings {
        let baseURL: String
        let apiKey: String
        let model: String
        let voice: String
        let provider: ProviderKind
    }

    /// The selected source and credentials needed to refresh provider metadata.
    struct MetadataSettingsSnapshot: Equatable {
        let baseURL: String
        let apiKey: String
        let model: String
        let provider: String
    }

    /// State that belongs exclusively to the active URL session task and is guarded by `stateQueue`.
    struct ActiveRequestContext {
        let task: URLSessionDataTask
        let taskIdentifier: Int
        let requestGeneration: UInt64
        let provider: ProviderKind
        let dataHandler: @Sendable (Data) -> Void
        var isErrorResponse = false
        var responseStatusCode: Int?
        var geminiEventParser = GeminiSSEEventParser()
        var geminiIncompletePCM = Data()
        var hasGeminiStreamFailure = false
        var providerAudioByteCount = 0
        var didRefuseInsecureRedirect = false
    }

    /// Creates a manager and optionally observes the lifecycle of its underlying URL session.
    init(configuration: URLSessionConfiguration = .default,
         sessionCreated: ((URLSession) -> Void)? = nil,
         sessionInvalidated: ((URLSession) -> Void)? = nil,
         secretStore: SecretStoring = KeychainSecretStore(),
         defaults: UserDefaults = .standard,
         requestBodyEncoder: @escaping (Data) throws -> Data = { $0 },
         audioDeliveryQueue: DispatchQueue = DispatchQueue(label: "com.clipboardtts.ttsaudiodelivery"),
         callbackAuthority: CallbackAuthorityLocking = RecursiveCallbackAuthority()) {
        let persistedProvider = defaults.string(forKey: SettingsKeys.ttsProvider) ?? "OpenAI"
        let provider = APIKeyProvider(selectedProvider: persistedProvider)
        self.selectedMetadataProvider = provider.settingsValue
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
        self.sessionInvalidated = sessionInvalidated
        self.audioDeliveryQueue = audioDeliveryQueue
        self.callbackAuthority = callbackAuthority

        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionCreated?(self.session)
        if let errorMessage = secretStartupState.errorMessage { self.lastError = errorMessage }
    }

    /// Updates the settings used by future TTS requests and invalidates metadata from a previous provider or endpoint.
    func updateSettings(baseURL: String,
                        apiKey: String,
                        model: String,
                        voice: String,
                        selectedProvider: String? = nil) {
        let invalidatedGeneration: UInt64? = stateQueue.sync {
            let nextMetadataProvider = selectedProvider ?? inferredMetadataProvider(for: baseURL)
            let metadataScopeChanged = self.baseURL != baseURL || self.selectedMetadataProvider != nextMetadataProvider
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.voice = voice
            self.selectedMetadataProvider = nextMetadataProvider

            guard metadataScopeChanged else { return nil }

            metadataGeneration &+= 1
            modelMetadataRequest?.task?.cancel()
            voiceMetadataRequest?.task?.cancel()
            modelMetadataRequest = nil
            voiceMetadataRequest = nil
            return metadataGeneration
        }
        if let invalidatedGeneration {
            clearMetadataLists(for: invalidatedGeneration)
        }
    }

    /// Updates only the voice captured by speech requests that start after this call.
    func updateVoice(_ voice: String) {
        stateQueue.sync {
            self.voice = voice
        }
    }

    /// Returns whether the manager's future-request settings belong to the supplied persisted provider.
    func isCurrentProvider(_ provider: String) -> Bool {
        stateQueue.sync {
            selectedMetadataProvider == provider
        }
    }

    /// Captures the selected source and credentials required to refresh metadata without changing request settings.
    func metadataSettingsSnapshot() -> MetadataSettingsSnapshot {
        stateQueue.sync {
            MetadataSettingsSnapshot(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                provider: selectedMetadataProvider
            )
        }
    }

    /// Captures the immutable settings one request attempt owns from start to finish.
    func requestSettingsSnapshot() -> RequestSettings {
        stateQueue.sync {
            RequestSettings(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                voice: voice,
                provider: ProviderKind(baseURL: baseURL, selectedProvider: selectedMetadataProvider)
            )
        }
    }

    /// Publishes a request failure on the main queue and marks the request as finished.
    func publishFailure(_ message: String, requestGeneration: UInt64? = nil) {
        let update: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.lastError = message
                self.isStreaming = false
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Clears a failure message only when it belongs to the latest request attempt.
    func clearLastError(requestGeneration: UInt64? = nil) {
        let update: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.lastError = nil
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Publishes the request lifecycle state on the main queue.
    func setStreaming(_ isStreaming: Bool, requestGeneration: UInt64? = nil) {
        let update: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.isStreaming = isStreaming
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Returns whether a completion still belongs to the latest stream generation.
    func isCurrentRequestGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return stateQueue.sync { requestGeneration == generation }
    }

    /// Defers request starts triggered by synchronous `@Published` observer re-entrancy.
    func deferRequestStartIfPublishingState(_ action: @escaping @Sendable () -> Void) -> Bool {
        let isPublishing = stateQueue.sync { requestStatePublicationDepth > 0 }
        guard isPublishing else { return false }
        DispatchQueue.main.async(execute: action)
        return true
    }

    /// Marks a `@Published` mutation so re-entrant observers cannot start a request mid-update.
    private func withRequestStatePublication(_ update: () -> Void) {
        stateQueue.sync { requestStatePublicationDepth += 1 }
        defer { stateQueue.sync { requestStatePublicationDepth -= 1 } }
        update()
    }

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
                    }
                }
                activeRequest = context
            }
        }
        completionHandler(shouldAllow ? .allow : .cancel)
    }

    /// Applies the endpoint transport rule to a redirect the provider asks the app to follow.
    ///
    /// URLSession follows redirects on its own, and a 307 or 308 replays the original method and
    /// body — the user's clipboard text — at whatever endpoint the response names, so checking the
    /// configured endpoint alone would let a provider move a request onto cleartext after it
    /// started. This runs for metadata tasks as well, which URLSession consults here even though
    /// they carry their own completion handler. A refused target records itself on the active
    /// speech request so completion reports the transport failure instead of the redirect status.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, EndpointTransportPolicy.permitsCredentials(url) {
            completionHandler(request)
            return
        }
        stateQueue.sync {
            guard var context = activeRequest, task.taskIdentifier == context.taskIdentifier else { return }
            context.didRefuseInsecureRedirect = true
            activeRequest = context
        }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        sessionInvalidated?(session)
    }
}
