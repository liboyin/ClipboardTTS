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
    
    init(configuration: URLSessionConfiguration = .default) {
        self.baseURL = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "https://api.openai.com/v1/audio/speech"
        self.apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        self.model = UserDefaults.standard.string(forKey: "ttsModel") ?? "tts-1"
        self.voice = UserDefaults.standard.string(forKey: "ttsVoice") ?? "alloy"
        
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    
    func updateSettings(baseURL: String, apiKey: String, model: String, voice: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
    }
    
    func streamTTS(text: String, dataHandler: @escaping (Data) -> Void) {
        guard let url = URL(string: baseURL) else {
            print("TTSNetworkManager Error: Invalid or missing baseURL (\(baseURL))")
            return
        }
        
        self.dataHandler = dataHandler
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "pcm"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("Failed to encode JSON: \(error)")
            return
        }
        
        currentTask?.cancel()
        
        isErrorResponse = false
        errorData.removeAll()
        
        DispatchQueue.main.async {
            self.isStreaming = true
        }
        
        print("Starting TTS stream to \(baseURL) with model: \(model), voice: \(voice)")
        currentTask = session.dataTask(with: request)
        currentTask?.resume()
    }
    
    func stopStreaming() {
        currentTask?.cancel()
        currentTask = nil
        DispatchQueue.main.async {
            self.isStreaming = false
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            print("Received HTTP Status Code: \(httpResponse.statusCode)")
            if !(200...299).contains(httpResponse.statusCode) {
                isErrorResponse = true
            }
        }
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isErrorResponse {
            errorData.append(data)
        } else {
            dataHandler?(data)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            self.isStreaming = false
        }
        
        if isErrorResponse {
            if let errorString = String(data: errorData, encoding: .utf8) {
                print("API Error Response: \(errorString)")
            } else {
                print("API Error Response: (unable to decode data)")
            }
        }
        
        if let error = error {
            print("Task completed with error: \(error.localizedDescription)")
        } else if !isErrorResponse {
            print("Task completed successfully.")
        }
    }
    
    struct OpenAIModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }
        let data: [Model]
    }
    
    func fetchAvailableModels(baseURL: String, apiKey: String) {
        let modelsURLString = baseURL.replacingOccurrences(of: "/audio/speech", with: "/models")
        guard let url = URL(string: modelsURLString) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else { return }
            do {
                let res = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
                DispatchQueue.main.async {
                    self.availableModels = res.data.map { $0.id }
                }
            } catch {
                print("Failed to decode models: \(error)")
            }
        }.resume()
    }
    
    func fetchAvailableVoices(baseURL: String, apiKey: String) {
        if baseURL.contains("api.openai.com") {
            DispatchQueue.main.async {
                self.availableVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
            }
            return
        }
        
        let voicesURLString = baseURL.replacingOccurrences(of: "/audio/speech", with: "/audio/voices")
        guard let url = URL(string: voicesURLString) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else { return }
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
