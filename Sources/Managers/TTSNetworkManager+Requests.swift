import Foundation

extension TTSNetworkManager {
    /// The required payload accepted by OpenAI-compatible speech endpoints.
    private struct OpenAICompatibleSpeechRequest: Encodable {
        let model: String
        let input: String
        let voice: String
        let responseFormat = "pcm"

        enum CodingKeys: String, CodingKey {
            case model
            case input
            case voice
            case responseFormat = "response_format"
        }
    }

    /// The endpoint one request may use, or the app-owned reason no request was built.
    enum RequestEndpoint: Equatable {
        case allowed(URL)
        /// The configured endpoint is not a usable HTTP or HTTPS URL.
        case malformed
        /// The endpoint would send the saved key and clipboard text over cleartext to a remote host.
        case insecureTransport
    }

    /// The single owner of the refusal shown for an unprotected endpoint or redirect target.
    static let insecureTransportFailure =
        "The TTS endpoint must use HTTPS unless it runs on localhost. Update Settings and try again."

    /// Builds a valid provider endpoint from a settings snapshot, refusing unprotected transport.
    ///
    /// Every speech request resolves its endpoint here, so the transport rule cannot be skipped by
    /// a provider whose base URL is configurable. The fixed OpenAI and Gemini endpoints are HTTPS
    /// and pass unchanged.
    func requestEndpoint(for settings: RequestSettings) -> RequestEndpoint {
        let urlString = settings.provider == .gemini
            ? "\(settings.baseURL)/models/\(settings.model):streamGenerateContent?alt=sse"
            : settings.baseURL
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              url.host != nil else {
            return .malformed
        }
        guard EndpointTransportPolicy.permitsCredentials(url) else {
            return .insecureTransport
        }
        return .allowed(url)
    }

    /// Returns whether Custom's two required request values contain meaningful text.
    func hasNonWhitespaceModelAndVoice(_ settings: RequestSettings) -> Bool {
        !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Encodes the request body for the provider captured when a speech request starts.
    func encodedRequestBody(text: String, settings: RequestSettings) throws -> Data {
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
            return try requestBodyEncoder(JSONSerialization.data(withJSONObject: geminiBody))
        }

        let payload = OpenAICompatibleSpeechRequest(
            model: settings.model,
            input: text,
            voice: settings.voice
        )
        return try requestBodyEncoder(JSONEncoder().encode(payload))
    }
}
