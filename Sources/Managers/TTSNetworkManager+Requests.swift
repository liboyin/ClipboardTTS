import Foundation

extension TTSNetworkManager {
    /// The required payload accepted by OpenAI-compatible speech endpoints, which Custom speaks.
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

    /// The single owner of the refusal shown when a redirect would hand the key to another origin.
    ///
    /// It names neither the configured endpoint nor the target, which is provider-controlled text,
    /// and says what did not happen: the user can otherwise only guess whether the key travelled.
    static let foreignOriginRedirectFailure =
        "The TTS service redirected to a different address, so your key was not sent. Check the API endpoint in Settings and try again."

    /// The header fields this app carries the saved API key in, and the single owner of that list.
    ///
    /// A request sets exactly one of them, and a redirect the app follows is given exactly these
    /// back from the request that authorized it, so a credential introduced at a request-building
    /// call site has to be named here too or a redirect would silently drop it.
    enum CredentialHeaderField {
        /// The bearer field OpenAI's Realtime handshake and OpenAI-compatible speech authenticate with.
        static let authorization = "Authorization"
        /// The field Gemini's own endpoint authenticates with.
        static let googleAPIKey = "x-goog-api-key"
        /// Every field above, so a followed redirect carries the credentials its request did.
        static let all = [authorization, googleAPIKey]
    }

    /// Builds a valid provider endpoint from a settings snapshot, refusing unprotected transport.
    ///
    /// Every speech request resolves its endpoint here, so the transport rule cannot be skipped by
    /// a provider whose base URL is configurable. The fixed OpenAI and Gemini endpoints are secure
    /// and pass unchanged. OpenAI always connects to its one Realtime endpoint, whatever base URL a
    /// caller supplied, so no provider identity a direct caller passes can send the OpenAI key
    /// elsewhere. Only OpenAI connects over WebSocket, so a WebSocket scheme is malformed for the
    /// providers that speak HTTP.
    func requestEndpoint(for settings: RequestSettings) -> RequestEndpoint {
        let url: URL?
        let schemes: Set<String>
        switch settings.provider {
        case .openAI:
            url = OpenAIRealtimeSpeech.url(model: settings.model)
            schemes = ["wss"]
        case .gemini:
            url = URL(string: "\(settings.baseURL)/models/\(settings.model):streamGenerateContent?alt=sse")
            schemes = ["http", "https"]
        case .custom:
            url = URL(string: settings.baseURL)
            schemes = ["http", "https"]
        }
        guard let url,
              let scheme = url.scheme,
              schemes.contains(scheme.lowercased()),
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
