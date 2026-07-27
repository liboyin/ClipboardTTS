import Foundation

class TTSNetworkManager: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var isStreaming = false
    @Published var availableModels: [String] = []
    @Published var availableVoices: [String] = []

    private var baseURL: String
    private var apiKey: String
    private var model: String
    private var voice: String

    private var session: URLSession!
    private var sessionInvalidated: ((URLSession) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.clipboardtts.ttsnetworkmanager")
    private var activeRequest: ActiveRequestContext?

    private enum ProviderKind: Equatable {
        case openAICompatible
        case gemini

        init(baseURL: String) {
            self = baseURL.contains("generativelanguage.googleapis.com") ? .gemini : .openAICompatible
        }
    }

    /// The values used to create one request, captured before the task is resumed.
    private struct RequestSettings {
        let baseURL: String
        let apiKey: String
        let model: String
        let voice: String
        let provider: ProviderKind
    }

    /// State that belongs exclusively to the active URL session task and is guarded by `stateQueue`.
    private struct ActiveRequestContext {
        let task: URLSessionDataTask
        let taskIdentifier: Int
        let settings: RequestSettings
        let provider: ProviderKind
        let dataHandler: (Data) -> Void
        var isErrorResponse = false
        var errorData = Data()
        var incrementalBuffer = Data()
    }

    /// Creates a manager and optionally observes the lifecycle of its underlying URL session.
    init(configuration: URLSessionConfiguration = .default,
         sessionCreated: ((URLSession) -> Void)? = nil,
         sessionInvalidated: ((URLSession) -> Void)? = nil) {
        let provider = UserDefaults.standard.string(forKey: SettingsKeys.ttsProvider) ?? "OpenAI"
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

        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionCreated?(self.session)
        self.sessionInvalidated = sessionInvalidated
    }

    func updateSettings(baseURL: String, apiKey: String, model: String, voice: String) {
        stateQueue.sync {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.voice = voice
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
                                      settings: RequestSettings,
                                      dataHandler: @escaping (Data) -> Void) {
        stateQueue.sync {
            // Swap all task-owned state together so a previous task cannot deliver its data to
            // the new handler in the window between cancellation and context replacement.
            activeRequest?.task.cancel()
            activeRequest = ActiveRequestContext(
                task: task,
                taskIdentifier: task.taskIdentifier,
                settings: settings,
                provider: settings.provider,
                dataHandler: dataHandler
            )
        }
    }

    func streamTTS(text: String, dataHandler: @escaping (Data) -> Void) {
        let settings = requestSettingsSnapshot()
        let urlString = settings.provider == .gemini
            ? "\(settings.baseURL)/models/\(settings.model):generateContent?key=\(settings.apiKey)"
            : settings.baseURL

        guard let url = URL(string: urlString) else {
            print("TTSNetworkManager Error: Invalid or missing baseURL (\(urlString))")
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
                bodyData = try JSONSerialization.data(withJSONObject: geminiBody)
            } else {
                let openaiBody: [String: Any] = [
                    "model": settings.model,
                    "input": text,
                    "voice": settings.voice,
                    "response_format": "pcm"
                ]
                bodyData = try JSONSerialization.data(withJSONObject: openaiBody)
            }
            request.httpBody = bodyData
        } catch {
            print("Failed to encode JSON: \(error)")
            return
        }

        let task = session.dataTask(with: request)
        replaceActiveRequest(with: task, settings: settings, dataHandler: dataHandler)

        DispatchQueue.main.async {
            self.isStreaming = true
        }

        print("Starting TTS stream to \(settings.baseURL) with model: \(settings.model), voice: \(settings.voice)")
        task.resume()
    }

    func stopStreaming() {
        stateQueue.sync {
            activeRequest?.task.cancel()
            activeRequest = nil
        }
        DispatchQueue.main.async {
            self.isStreaming = false
        }
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
                    print("Received HTTP Status Code: \(httpResponse.statusCode)")
                    if !(200...299).contains(httpResponse.statusCode) {
                        context.isErrorResponse = true
                    }
                }
                activeRequest = context
            }
        }
        completionHandler(shouldAllow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateQueue.sync {
            guard var context = activeRequest,
                  dataTask.taskIdentifier == context.taskIdentifier else { return }
            if context.isErrorResponse {
                context.errorData.append(data)
            } else if context.provider == .gemini {
                context.incrementalBuffer.append(data)
            } else {
                context.dataHandler(data)
            }
            activeRequest = context
        }
    }

    struct TaskCompletionResult {
        let audioData: Data?
        let handler: ((Data) -> Void)?
        let errorString: String?
        let hadError: Bool
        let isStale: Bool
    }

    private func processCompletedTask(_ task: URLSessionTask) -> TaskCompletionResult {
        return stateQueue.sync {
            guard let context = activeRequest, task.taskIdentifier == context.taskIdentifier else {
                return TaskCompletionResult(audioData: nil, handler: nil, errorString: nil, hadError: false, isStale: true)
            }

            var audioData: Data?
            if context.provider == .gemini && !context.isErrorResponse {
                audioData = extractGeminiAudioData(from: context.incrementalBuffer)
            }

            let errorString = context.isErrorResponse ? String(data: context.errorData, encoding: .utf8) : nil

            let result = TaskCompletionResult(
                audioData: audioData,
                handler: context.dataHandler,
                errorString: errorString,
                hadError: context.isErrorResponse,
                isStale: false
            )

            activeRequest = nil

            return result
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = processCompletedTask(task)
        if result.isStale { return }

        if let audioData = result.audioData {
            result.handler?(audioData)
        }

        if result.hadError {
            let msg = result.errorString ?? "(unable to decode data)"
            print("API Error Response: \(msg)")
        }

        DispatchQueue.main.async {
            self.isStreaming = false
        }

        if let error = error {
            print("Task completed with error: \(error.localizedDescription)")
        } else if !result.hadError {
            print("Task completed successfully.")
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        sessionInvalidated?(session)
    }

    private func extractGeminiAudioData(from buffer: Data) -> Data? {
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

    struct OpenAIModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }
        let data: [Model]
    }

    func fetchAvailableModels(baseURL: String, apiKey: String) {
        if baseURL.contains("generativelanguage.googleapis.com") {
            self.availableModels = ["gemini-3.1-flash-tts-preview"]
            return
        }

        let modelsURLString = baseURL.replacingOccurrences(of: "/audio/speech", with: "/models")
        guard let url = URL(string: modelsURLString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        self.session.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else { return }

            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("Failed to fetch models: HTTP \(httpResponse.statusCode)")
                return
            }

            do {
                let res = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
                DispatchQueue.main.async {
                    self.availableModels = res.data.map { $0.id }.filter { $0.contains("tts") }
                }
            } catch {
                print("Failed to decode models: \(error)")
            }
        }.resume()
    }

    func fetchAvailableVoices(baseURL: String, apiKey: String) {
        if baseURL.contains("api.openai.com") {
            self.availableVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
            return
        }

        if baseURL.contains("generativelanguage.googleapis.com") {
            self.availableVoices = ["Aoede", "Charon", "Fenrir", "Kore", "Puck"]
            return
        }

        let voicesURLString = baseURL.replacingOccurrences(of: "/audio/speech", with: "/audio/voices")
        guard let url = URL(string: voicesURLString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        self.session.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else { return }

            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("Failed to fetch voices: HTTP \(httpResponse.statusCode)")
                return
            }

            do {
                if let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    var fetchedVoices: [String] = []
                    if let dataArray = dict["data"] as? [[String: Any]] {
                        fetchedVoices = dataArray.compactMap { $0["id"] as? String ?? $0["name"] as? String }
                    } else if let voicesArray = dict["voices"] as? [String] {
                        fetchedVoices = voicesArray
                    }

                    if !fetchedVoices.isEmpty {
                        DispatchQueue.main.async {
                            self.availableVoices = fetchedVoices
                        }
                    }
                }
            } catch {
                print("Failed to decode voices: \(error)")
            }
        }.resume()
    }
}
