import Foundation

class TTSNetworkManager: NSObject, ObservableObject, URLSessionDataDelegate {
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
    private var sessionInvalidated: ((URLSession) -> Void)?
    private let requestBodyEncoder: ([String: Any]) throws -> Data

    /// Serializes active-request state; client callbacks are captured here but always invoked after leaving this queue.
    let stateQueue = DispatchQueue(label: "com.clipboardtts.ttsnetworkmanager")
    var activeRequest: ActiveRequestContext?; private var requestGeneration: UInt64 = 0
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

        init(baseURL: String) {
            self = baseURL.contains("generativelanguage.googleapis.com") ? .gemini : .openAICompatible
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

    /// State that belongs exclusively to the active URL session task and is guarded by `stateQueue`.
    struct ActiveRequestContext {
        let task: URLSessionDataTask
        let taskIdentifier: Int
        let requestGeneration: UInt64
        let provider: ProviderKind
        let dataHandler: (Data) -> Void
        var isErrorResponse = false
        var responseStatusCode: Int?
        var incrementalBuffer = Data()
        var providerAudioByteCount = 0
    }

    /// Creates a manager and optionally observes the lifecycle of its underlying URL session.
    init(configuration: URLSessionConfiguration = .default,
         sessionCreated: ((URLSession) -> Void)? = nil,
         sessionInvalidated: ((URLSession) -> Void)? = nil,
         requestBodyEncoder: @escaping ([String: Any]) throws -> Data = {
             try JSONSerialization.data(withJSONObject: $0)
         }) {
        let provider = UserDefaults.standard.string(forKey: SettingsKeys.ttsProvider) ?? "OpenAI"
        self.selectedMetadataProvider = provider
        if provider == "OpenAI" {
            self.baseURL = "https://api.openai.com/v1/audio/speech"
            self.apiKey = UserDefaults.standard.string(forKey: SettingsKeys.legacyOpenAIAPIKey) ?? ""
            self.model = UserDefaults.standard.string(forKey: SettingsKeys.openAIModel) ?? "tts-1"
            self.voice = UserDefaults.standard.string(forKey: SettingsKeys.openAIVoice) ?? "alloy"
        } else if provider == "Gemini" {
            self.baseURL = "https://generativelanguage.googleapis.com/v1beta"
            self.apiKey = UserDefaults.standard.string(forKey: SettingsKeys.legacyGeminiAPIKey) ?? ""
            self.model = UserDefaults.standard.string(forKey: SettingsKeys.geminiModel) ?? "gemini-3.1-flash-tts-preview"
            self.voice = UserDefaults.standard.string(forKey: SettingsKeys.geminiVoice) ?? "Aoede"
        } else {
            self.baseURL = UserDefaults.standard.string(forKey: SettingsKeys.apiBaseURL) ?? "https://api.openai.com/v1/audio/speech"
            self.apiKey = UserDefaults.standard.string(forKey: SettingsKeys.legacyCustomAPIKey) ?? ""
            self.model = ""
            self.voice = ""
        }
        self.requestBodyEncoder = requestBodyEncoder

        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionCreated?(self.session)
        self.sessionInvalidated = sessionInvalidated
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

    private func requestSettingsSnapshot() -> RequestSettings {
        stateQueue.sync {
            RequestSettings(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                voice: voice,
                provider: ProviderKind(baseURL: baseURL)
            )
        }
    }

    private func replaceActiveRequest(with task: URLSessionDataTask,
                                      provider: ProviderKind,
                                      requestGeneration: UInt64,
                                      dataHandler: @escaping (Data) -> Void) -> Bool {
        stateQueue.sync {
            // Swap all task-owned state together so a previous task cannot deliver its data to
            // the new handler in the window between cancellation and context replacement.
            guard self.requestGeneration == requestGeneration else { return false }
            activeRequest?.task.cancel()
            activeRequest = ActiveRequestContext(
                task: task,
                taskIdentifier: task.taskIdentifier,
                requestGeneration: requestGeneration,
                provider: provider,
                dataHandler: dataHandler
            )
            return true
        }
    }

    /// Cancels the active stream and advances the generation for a new request attempt.
    private func beginRequestAttempt() -> UInt64 {
        stateQueue.sync {
            activeRequest?.task.cancel()
            activeRequest = nil
            requestGeneration &+= 1
            return requestGeneration
        }
    }

    /// Publishes a request failure on the main queue and marks the request as finished.
    func publishFailure(_ message: String, requestGeneration: UInt64? = nil) {
        let update = { [weak self] in
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
        let update = { [weak self] in
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
        let update = { [weak self] in
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
    private func isCurrentRequestGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return stateQueue.sync { requestGeneration == generation }
    }

    /// Defers request starts triggered by synchronous `@Published` observer re-entrancy.
    private func deferRequestStartIfPublishingState(_ action: @escaping () -> Void) -> Bool {
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

    /// Builds a valid provider endpoint from a settings snapshot.
    private func requestURL(for settings: RequestSettings) -> URL? {
        let urlString = settings.provider == .gemini
            ? "\(settings.baseURL)/models/\(settings.model):generateContent?key=\(settings.apiKey)"
            : settings.baseURL
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              url.host != nil else {
            return nil
        }
        return url
    }

    func streamTTS(text: String, dataHandler: @escaping (Data) -> Void) {
        if deferRequestStartIfPublishingState({ [weak self] in
            self?.streamTTS(text: text, dataHandler: dataHandler)
        }) {
            return
        }
        let requestGeneration = beginRequestAttempt(); clearLastError(requestGeneration: requestGeneration)
        let settings = requestSettingsSnapshot()
        guard let url = requestURL(for: settings) else {
            publishFailure("TTS configuration is invalid. Check the API endpoint and try again.", requestGeneration: requestGeneration)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if settings.provider == .openAICompatible {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let bodyData: Data
            if settings.provider == .gemini {
                let geminiBody: [String: Any] = [
                    "contents": [["parts": [["text": text]]]],
                    "generationConfig": [
                        "responseModalities": ["AUDIO"],
                        "speechConfig": [
                            "voiceConfig": [
                                "prebuiltVoiceConfig": [
                                    "voiceName": settings.voice
                                ]
                            ]
                        ]
                    ]
                ]
                bodyData = try requestBodyEncoder(geminiBody)
            } else {
                let openaiBody: [String: Any] = [
                    "model": settings.model,
                    "input": text,
                    "voice": settings.voice,
                    "response_format": "pcm"
                ]
                bodyData = try requestBodyEncoder(openaiBody)
            }
            request.httpBody = bodyData
        } catch {
            publishFailure("Couldn't prepare the speech request. Check the settings and try again.", requestGeneration: requestGeneration)
            return
        }

        let task = session.dataTask(with: request)
        guard replaceActiveRequest(
            with: task,
            provider: settings.provider,
            requestGeneration: requestGeneration,
            dataHandler: dataHandler
        ) else {
            task.cancel()
            return
        }

        setStreaming(true, requestGeneration: requestGeneration); task.resume()
    }

    func stopStreaming() {
        let requestGeneration = beginRequestAttempt()
        clearLastError(requestGeneration: requestGeneration)
        setStreaming(false, requestGeneration: requestGeneration)
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

    /// Validates and records an incoming task chunk before delivering OpenAI-compatible audio to the client.
    ///
    /// State validation and mutation finish under `stateQueue`. The client handler is captured there
    /// but invoked only after the queue is released, so it may synchronously stop or replace the stream.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let dataHandler: ((Data) -> Void)? = stateQueue.sync {
            guard var context = activeRequest, dataTask.taskIdentifier == context.taskIdentifier else { return nil }
            defer { activeRequest = context }
            if context.isErrorResponse { return nil }
            if context.provider == .gemini { context.incrementalBuffer.append(data); return nil }
            guard !data.isEmpty else { return nil }
            context.providerAudioByteCount += data.count
            return context.dataHandler
        }
        dataHandler?(data)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        sessionInvalidated?(session)
    }

    /// Decodes the complete Gemini response's first inline-audio payload, if present.
    func extractGeminiAudioData(from buffer: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let inlineData = parts.first?["inlineData"] as? [String: Any],
              let base64String = inlineData["data"] as? String else {
            return nil
        }
        return Data(base64Encoded: base64String)
    }

}
