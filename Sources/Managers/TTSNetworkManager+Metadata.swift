import Foundation

/// A published model or voice suggestion list together with the provider it was fetched for.
///
/// Settings renders a newly selected provider's saved model and voice one render before its
/// `onChange` can resynchronize the manager, so the previous provider's list is still published at
/// that point. Naming the owner on the list itself is what lets a form refuse it: SwiftUI documents
/// a picker whose selection has no matching tag as undefined, and offering one provider's choices
/// under another provider's configuration would be wrong even where it is defined.
struct ProviderSuggestions: Equatable {
    /// The state before any list is published, and the one an invalidated metadata scope returns to.
    static let unpublished = ProviderSuggestions(provider: "", values: [])

    /// The persisted provider value these suggestions were fetched for.
    let provider: String
    let values: [String]

    /// The suggestions when they belong to `provider`, and none otherwise.
    func values(for provider: String) -> [String] {
        self.provider == provider ? values : []
    }
}

extension TTSNetworkManager {
    enum MetadataKind {
        case models
        case voices
    }

    struct MetadataRequestToken: Equatable {
        let identifier: UInt64
        let generation: UInt64
        /// The provider this request's results may be published for, carried on the token so a
        /// publication takes its identity from the request that earned it rather than from settings
        /// that may have changed since.
        let provider: String
    }

    struct MetadataRequest {
        let token: MetadataRequestToken
        /// The started discovery task, which only a models request has: no supported provider
        /// offers voice discovery, so a voice request publishes a documented constant instead.
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
    /// truth for the Settings suggestions, which are the only place a voice is chosen. Transcribed
    /// from the "Voice options" table of https://ai.google.dev/gemini-api/docs/speech-generation,
    /// verified 2026-08-20; it must be re-verified against that guide whenever Google changes the
    /// documented set.
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

    /// Builds a metadata endpoint, refusing one whose transport would expose the key it carries.
    ///
    /// A discovery request attaches the same `Authorization: Bearer` credential as a speech
    /// request, so it answers to the same rule as `requestEndpoint(for:)`. A refusal is silent, as
    /// every other metadata failure is: the lists stay as they were and no request is created.
    /// Only model discovery reaches this, and only Settings' fixed OpenAI endpoint reaches that,
    /// so the refusal is defense in depth for a caller that later derives the URL differently.
    private func metadataURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString), EndpointTransportPolicy.permitsCredentials(url) else { return nil }
        return url
    }

    private func beginMetadataRequest(for kind: MetadataKind,
                                      source: MetadataSource) -> MetadataRequestToken? {
        stateQueue.sync {
            guard baseURL == source.baseURL, selectedMetadataProvider == source.provider else { return nil }

            // Only a models request owns a URLSession task; a voice request publishes a
            // documented constant, so replacing one needs no cancellation.
            if case .models = kind { modelMetadataRequest?.task?.cancel() }

            nextMetadataRequestIdentifier &+= 1
            let token = MetadataRequestToken(
                identifier: nextMetadataRequestIdentifier,
                generation: metadataGeneration,
                provider: source.provider
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

    /// Records a started discovery task on the model request that owns `token`, if it is still current.
    private func attachModelMetadataTask(_ task: URLSessionDataTask, token: MetadataRequestToken) -> Bool {
        stateQueue.sync {
            guard var request = modelMetadataRequest, request.token == token else { return false }
            request.task = task
            modelMetadataRequest = request
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
            let suggestions = ProviderSuggestions(provider: token.provider, values: values)
            switch kind {
            case .models:
                self.modelSuggestions = suggestions
            case .voices:
                self.voiceSuggestions = suggestions
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

    /// Returns the pending model discovery task so tests can verify it is cancelled before teardown.
    func modelMetadataTaskForTesting() -> URLSessionDataTask? {
        stateQueue.sync { modelMetadataRequest?.task }
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
            self.modelSuggestions = .unpublished
            self.voiceSuggestions = .unpublished
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
        guard attachModelMetadataTask(task, token: token) else {
            task.cancel()
            return
        }
        task.resume()
    }

    /// Publishes the selected provider's voice catalog, replacing only an equally current voice request.
    ///
    /// No provider the app supports offers voice discovery, so this creates no request and needs no
    /// credential: OpenAI and Gemini publish the documented constants above, and a Custom endpoint
    /// has no discovery contract, which is why `SettingsView.fetchMetadata` does not ask for one.
    /// The catalog still travels the guarded token path, because publication is asynchronous and a
    /// provider or endpoint the user changes in that window must invalidate it.
    func fetchAvailableVoices(baseURL: String, selectedProvider: String) {
        let source = MetadataSource(baseURL: baseURL, provider: selectedProvider)
        guard let token = beginMetadataRequest(for: .voices, source: source) else { return }
        switch selectedProvider {
        case "OpenAI":
            publishMetadata(
                openAIVoices(for: metadataSettingsSnapshot().model),
                for: .voices,
                token: token
            )
        case "Gemini":
            publishMetadata(Self.geminiVoices, for: .voices, token: token)
        default:
            finishMetadataRequest(for: .voices, token: token)
        }
    }

    private func openAIVoices(for model: String) -> [String] {
        switch model {
        case "tts-1", "tts-1-hd":
            return Self.legacyOpenAIVoices
        default:
            return Self.currentOpenAIVoices
        }
    }
}
