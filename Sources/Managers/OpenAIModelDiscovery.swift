import Foundation

/// The OpenAI-compatible model-discovery contract: where a speech endpoint's model list is asked
/// for, and how the answer reads.
///
/// Both ends are pure, so the endpoint a speech URL implies and the payload shape can be stated
/// without a session or a manager. What the request carries and when its result may be published
/// stay with `TTSNetworkManager+Metadata`: this type decides nothing about freshness.
enum OpenAIModelDiscovery {
    /// The models list OpenAI documents, read for model identifiers alone.
    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    /// The discovery endpoint a speech endpoint implies, refusing one whose transport would expose
    /// the key it carries.
    ///
    /// A discovery request attaches the same `Authorization: Bearer` credential as a speech request,
    /// so it answers to the same rule as `TTSNetworkManager.requestEndpoint(for:)`. A refusal is
    /// silent, as every other metadata failure is: `nil` means no request is created and the
    /// published lists stay as they were. Only Settings' fixed OpenAI endpoint reaches this today,
    /// so the refusal is defense in depth for a caller that later derives the URL differently.
    ///
    /// A base URL that names no `/audio/speech` path is asked as it stands: a deployment serving
    /// speech elsewhere is the one that knows where its model list is, and inventing a path for it
    /// would send the saved key somewhere the user never configured.
    static func url(forSpeechEndpoint baseURL: String) -> URL? {
        let modelsURLString = baseURL.replacingOccurrences(of: "/audio/speech", with: "/models")
        guard let url = URL(string: modelsURLString),
              EndpointTransportPolicy.permitsCredentials(url) else { return nil }
        return url
    }

    /// The TTS models a discovery payload declares, or `nil` when it cannot be read as that payload.
    ///
    /// A models list names every model the deployment serves, so only identifiers containing `tts`
    /// are offered: the rest cannot speak, and suggesting one would configure a request that fails.
    static func models(from data: Data) -> [String]? {
        guard let response = try? JSONDecoder().decode(ModelsResponse.self, from: data) else { return nil }
        return response.data.map(\.id).filter { $0.contains("tts") }
    }
}
