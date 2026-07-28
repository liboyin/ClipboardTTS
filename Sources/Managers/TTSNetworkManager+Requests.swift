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
