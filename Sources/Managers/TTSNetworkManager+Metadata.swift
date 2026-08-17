import Foundation

extension TTSNetworkManager {
    enum MetadataKind {
        case models
        case voices
    }

    struct MetadataRequestToken: Equatable {
        let identifier: UInt64
        let generation: UInt64
    }

    struct MetadataRequest {
        let token: MetadataRequestToken
        var task: URLSessionDataTask?
    }

    private static let legacyOpenAIVoices = [
        "alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"
    ]
    private static let currentOpenAIVoices = [
        "alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage",
        "shimmer", "verse", "marin", "cedar"
    ]
    /// The complete Gemini TTS voice catalog, in the order Google's guide lists it.
    ///
    /// Gemini documents no voice-discovery endpoint, so this list is the app's only source of
    /// truth for both the menu and the Settings suggestions. Transcribed from the "Voice options"
    /// table of https://ai.google.dev/gemini-api/docs/speech-generation, verified 2026-08-16;
    /// it must be re-verified against that guide whenever Google changes the documented set.
    private static let geminiVoices = [
        "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe",
        "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib",
        "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima",
        "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"
    ]

    private struct MetadataSource: Equatable {
        let baseURL: String
        let provider: String
    }

    private struct OpenAIModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    func inferredMetadataProvider(for baseURL: String) -> String {
        baseURL.contains("generativelanguage.googleapis.com") ? "Gemini" : "OpenAICompatible"
    }

    /// Builds a metadata endpoint, refusing one whose transport would expose the key it carries.
    ///
    /// A discovery request attaches the same `Authorization: Bearer` credential as a speech
    /// request, so it answers to the same rule as `requestEndpoint(for:)`. A refusal is silent, as
    /// every other metadata failure is: the lists stay as they were and no request is created.
    private func metadataURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString), EndpointTransportPolicy.permitsCredentials(url) else { return nil }
        return url
    }

    private func beginMetadataRequest(for kind: MetadataKind,
                                      source: MetadataSource) -> MetadataRequestToken? {
        stateQueue.sync {
            guard baseURL == source.baseURL, selectedMetadataProvider == source.provider else { return nil }

            switch kind {
            case .models:
                modelMetadataRequest?.task?.cancel()
            case .voices:
                voiceMetadataRequest?.task?.cancel()
            }

            nextMetadataRequestIdentifier &+= 1
            let token = MetadataRequestToken(
                identifier: nextMetadataRequestIdentifier,
                generation: metadataGeneration
            )
            let request = MetadataRequest(token: token, task: nil)
            switch kind {
            case .models:
                modelMetadataRequest = request
            case .voices:
                voiceMetadataRequest = request
            }
            return token
        }
    }

    private func attach(_ task: URLSessionDataTask,
                        toMetadataRequestFor kind: MetadataKind,
                        token: MetadataRequestToken) -> Bool {
        stateQueue.sync {
            switch kind {
            case .models:
                guard var request = modelMetadataRequest, request.token == token else { return false }
                request.task = task
                modelMetadataRequest = request
            case .voices:
                guard var request = voiceMetadataRequest, request.token == token else { return false }
                request.task = task
                voiceMetadataRequest = request
            }
            return true
        }
    }

    private func finishMetadataRequest(for kind: MetadataKind, token: MetadataRequestToken) {
        stateQueue.sync {
            switch kind {
            case .models where modelMetadataRequest?.token == token:
                modelMetadataRequest = nil
            case .voices where voiceMetadataRequest?.token == token:
                voiceMetadataRequest = nil
            default:
                break
            }
        }
    }

    private func publishMetadata(_ values: [String],
                                 for kind: MetadataKind,
                                 token: MetadataRequestToken) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard self.completeMetadataRequest(for: kind, token: token) else { return }
            self.isPublishingMetadata = true
            defer { self.isPublishingMetadata = false }
            switch kind {
            case .models:
                self.availableModels = values
            case .voices:
                self.availableVoices = values
            }
        }
    }

    private func completeMetadataRequest(for kind: MetadataKind, token: MetadataRequestToken) -> Bool {
        stateQueue.sync {
            switch kind {
            case .models where modelMetadataRequest?.token == token:
                modelMetadataRequest = nil
                return true
            case .voices where voiceMetadataRequest?.token == token:
                voiceMetadataRequest = nil
                return true
            default:
                return false
            }
        }
    }

    #if DEBUG
    /// Returns a pending token so tests can simulate a completion already queued at cancellation time.
    func metadataTokenForTesting(for kind: MetadataKind) -> MetadataRequestToken? {
        stateQueue.sync {
            switch kind {
            case .models:
                return modelMetadataRequest?.token
            case .voices:
                return voiceMetadataRequest?.token
            }
        }
    }

    /// Returns the pending metadata task so tests can verify it is cancelled before teardown.
    func metadataTaskForTesting(for kind: MetadataKind) -> URLSessionDataTask? {
        stateQueue.sync {
            switch kind {
            case .models:
                return modelMetadataRequest?.task
            case .voices:
                return voiceMetadataRequest?.task
            }
        }
    }

    /// Delivers a synthetic late completion through the production publication guard.
    func publishMetadataForTesting(_ values: [String],
                                   for kind: MetadataKind,
                                   token: MetadataRequestToken) {
        publishMetadata(values, for: kind, token: token)
    }
    #endif

    func clearMetadataLists(for generation: UInt64) {
        let clearLists: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.stateQueue.sync(execute: { self.metadataGeneration == generation }) else { return }
            self.availableModels = []
            self.availableVoices = []
        }

        if Thread.isMainThread, !isPublishingMetadata {
            clearLists()
        } else {
            DispatchQueue.main.async(execute: clearLists)
        }
    }

    /// Fetches models for the selected metadata source, replacing only an equally current model request.
    func fetchAvailableModels(baseURL: String, apiKey: String, selectedProvider: String) {
        let source = MetadataSource(baseURL: baseURL, provider: selectedProvider)
        guard let token = beginMetadataRequest(for: .models, source: source) else { return }
        if baseURL.contains("generativelanguage.googleapis.com") {
            publishMetadata(["gemini-3.1-flash-tts-preview"], for: .models, token: token)
            return
        }

        let modelsURLString = baseURL.replacingOccurrences(of: "/audio/speech", with: "/models")
        guard let url = metadataURL(from: modelsURLString) else {
            finishMetadataRequest(for: .models, token: token)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self, let data, error == nil else {
                self?.finishMetadataRequest(for: .models, token: token)
                return
            }
            guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else {
                self.finishMetadataRequest(for: .models, token: token)
                return
            }

            guard let response = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data) else {
                self.finishMetadataRequest(for: .models, token: token)
                return
            }
            self.publishMetadata(response.data.map(\.id).filter { $0.contains("tts") }, for: .models, token: token)
        }
        guard attach(task, toMetadataRequestFor: .models, token: token) else {
            task.cancel()
            return
        }
        task.resume()
    }

    /// Fetches voices for the selected metadata source, replacing only an equally current voice request.
    func fetchAvailableVoices(baseURL: String, apiKey: String, selectedProvider: String) {
        let source = MetadataSource(baseURL: baseURL, provider: selectedProvider)
        guard let token = beginMetadataRequest(for: .voices, source: source) else { return }
        if selectedProvider == "OpenAI" {
            publishMetadata(
                openAIVoices(for: metadataSettingsSnapshot().model),
                for: .voices,
                token: token
            )
            return
        }
        if selectedProvider == "Gemini" {
            publishMetadata(Self.geminiVoices, for: .voices, token: token)
            return
        }

        let voicesURLString = baseURL.replacingOccurrences(of: "/audio/speech", with: "/audio/voices")
        guard let url = metadataURL(from: voicesURLString) else {
            finishMetadataRequest(for: .voices, token: token)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self, let data, error == nil else {
                self?.finishMetadataRequest(for: .voices, token: token)
                return
            }
            guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
                  let voices = decodeVoices(from: data) else {
                self.finishMetadataRequest(for: .voices, token: token)
                return
            }
            self.publishMetadata(voices, for: .voices, token: token)
        }
        guard attach(task, toMetadataRequestFor: .voices, token: token) else {
            task.cancel()
            return
        }
        task.resume()
    }

    /// Refreshes voice metadata for the manager's selected provider without reconstructing request settings.
    func fetchAvailableVoicesForCurrentProvider() {
        let settings = metadataSettingsSnapshot()
        guard settings.provider != APIKeyProvider.custom.settingsValue else { return }
        fetchAvailableVoices(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            selectedProvider: settings.provider
        )
    }

    private func openAIVoices(for model: String) -> [String] {
        switch model {
        case "tts-1", "tts-1-hd":
            return Self.legacyOpenAIVoices
        default:
            return Self.currentOpenAIVoices
        }
    }

    private func decodeVoices(from data: Data) -> [String]? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let data = response["data"] {
            guard let entries = data as? [[String: Any]] else { return nil }
            let voices = entries.compactMap { $0["id"] as? String ?? $0["name"] as? String }
            return voices.count == entries.count ? voices : nil
        }
        guard let voices = response["voices"] else { return nil }
        return voices as? [String]
    }
}
