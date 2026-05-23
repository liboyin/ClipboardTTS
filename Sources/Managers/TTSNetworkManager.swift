import Foundation

class TTSNetworkManager: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var isStreaming = false
    
    private var baseURL: String = ""
    private var apiKey: String = ""
    private var model: String = ""
    private var voice: String = ""
    
    private var session: URLSession!
    private var currentTask: URLSessionDataTask?
    private var dataHandler: ((Data) -> Void)?
    
    private var isErrorResponse = false
    private var errorData = Data()
    
    init(configuration: URLSessionConfiguration = .default) {
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
        guard let url = URL(string: baseURL) else { return }
        
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
}
