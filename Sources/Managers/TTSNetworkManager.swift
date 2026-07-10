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
    private var currentTask: URLSessionDataTask?
    private var dataHandler: ((Data) -> Void)?

    private var isErrorResponse = false
    private var errorData = Data()
    private var geminiBuffer = Data()

    private let stateQueue = DispatchQueue(label: "com.clipboardtts.ttsnetworkmanager")
    private var activeTaskIdentifier: Int?

    init(configuration: URLSessionConfiguration = .default) {
        let provider = UserDefaults.standard.string(forKey: "ttsProvider") ?? "OpenAI"
        if provider == "OpenAI" {
            self.baseURL = "https://api.openai.com/v1/audio/speech"
            self.apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
            self.model = UserDefaults.standard.string(forKey: "openaiModel") ?? "tts-1"
            self.voice = UserDefaults.standard.string(forKey: "openaiVoice") ?? "alloy"
        } else if provider == "Gemini" {
            self.baseURL = "https://generativelanguage.googleapis.com/v1beta"
            self.apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
            self.model = UserDefaults.standard.string(forKey: "geminiModel") ?? "gemini-3.1-flash-tts-preview"
            self.voice = UserDefaults.standard.string(forKey: "geminiVoice") ?? "Aoede"
        } else {
            self.baseURL = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "https://api.openai.com/v1/audio/speech"
            self.apiKey = UserDefaults.standard.string(forKey: "customAPIKey") ?? ""
            self.model = ""
            self.voice = ""
        }

        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private var isGeminiEndpoint: Bool {
        baseURL.contains("generativelanguage.googleapis.com")
    }

    func updateSettings(baseURL: String, apiKey: String, model: String, voice: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
    }

    func streamTTS(text: String, dataHandler: @escaping (Data) -> Void) {
        let isGemini = isGeminiEndpoint
        let urlString = isGemini ? "\(baseURL)/models/\(model):generateContent?key=\(apiKey)" : baseURL

        guard let url = URL(string: urlString) else {
            print("TTSNetworkManager Error: Invalid or missing baseURL (\(urlString))")
            return
        }

        stateQueue.sync {
            self.dataHandler = dataHandler
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if !isGemini {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let bodyData: Data
            if isGemini {
                let geminiBody: [String: Any] = [
                    "contents": [["parts": [["text": text]]]],
                    "generationConfig": [
                        "responseModalities": ["AUDIO"],
                        "speechConfig": [
                            "voiceConfig": [
                                "prebuiltVoiceConfig": [
                                    "voiceName": voice
                                ]
                            ]
                        ]
                    ]
                ]
                bodyData = try JSONSerialization.data(withJSONObject: geminiBody)
            } else {
                let openaiBody: [String: Any] = [
                    "model": model,
                    "input": text,
                    "voice": voice,
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
        stateQueue.sync {
            currentTask?.cancel()
            currentTask = task
            activeTaskIdentifier = task.taskIdentifier

            isErrorResponse = false
            errorData.removeAll()
            geminiBuffer.removeAll()
        }

        DispatchQueue.main.async {
            self.isStreaming = true
        }

        print("Starting TTS stream to \(baseURL) with model: \(model), voice: \(voice)")
        task.resume()
    }

    func stopStreaming() {
        stateQueue.sync {
            currentTask?.cancel()
            currentTask = nil
            activeTaskIdentifier = nil
            dataHandler = nil
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
            if dataTask.taskIdentifier == activeTaskIdentifier {
                shouldAllow = true
                if let httpResponse = response as? HTTPURLResponse {
                    print("Received HTTP Status Code: \(httpResponse.statusCode)")
                    if !(200...299).contains(httpResponse.statusCode) {
                        isErrorResponse = true
                    }
                }
            }
        }
        completionHandler(shouldAllow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateQueue.sync {
            guard dataTask.taskIdentifier == activeTaskIdentifier else { return }
            if isErrorResponse {
                errorData.append(data)
            } else if isGeminiEndpoint {
                geminiBuffer.append(data)
            } else {
                dataHandler?(data)
            }
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
            if task.taskIdentifier != activeTaskIdentifier {
                return TaskCompletionResult(audioData: nil, handler: nil, errorString: nil, hadError: false, isStale: true)
            }

            var audioData: Data?
            if isGeminiEndpoint && !isErrorResponse {
                audioData = extractGeminiAudioData(from: geminiBuffer)
            }

            var errorString: String?
            if isErrorResponse {
                errorString = String(data: errorData, encoding: .utf8)
            }

            let result = TaskCompletionResult(
                audioData: audioData,
                handler: dataHandler,
                errorString: errorString,
                hadError: isErrorResponse,
                isStale: false
            )

            activeTaskIdentifier = nil
            currentTask = nil
            dataHandler = nil

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
