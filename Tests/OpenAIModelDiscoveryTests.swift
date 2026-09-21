import XCTest
@testable import ClipboardTTSApp

/// Where an OpenAI-compatible model list is asked for, and how the answer reads.
///
/// Both halves are decided before any request exists, so this suite needs neither a session nor a
/// manager. Whether a result may still be published belongs to the manager's token guard, and the
/// credential the request carries belongs to `TTSNetworkManager+Metadata`.
final class OpenAIModelDiscoveryTests: XCTestCase {
    func testDiscoveryAsksTheModelsPathOfAnOpenAICompatibleSpeechEndpoint() {
        // WHY: Settings stores the speech endpoint, not a discovery one, so the models path has to
        // be derived from it. Asking the speech endpoint for a model list would send the saved key
        // to a path that answers with audio or an error.
        XCTAssertEqual(
            OpenAIModelDiscovery.url(forSpeechEndpoint: "https://api.openai.com/v1/audio/speech"),
            URL(string: "https://api.openai.com/v1/models")
        )
    }

    func testAnEndpointThatNamesNoSpeechPathIsAskedExactlyAsConfigured() {
        // WHY: A deployment serving speech somewhere else is the one that knows where its model list
        // is. Appending a path of the app's own invention would send the saved key to an address the
        // user never configured, so the configured URL is used unchanged instead.
        XCTAssertEqual(
            OpenAIModelDiscovery.url(forSpeechEndpoint: "https://custom.api/v1/models"),
            URL(string: "https://custom.api/v1/models")
        )
        XCTAssertEqual(
            OpenAIModelDiscovery.url(forSpeechEndpoint: "https://custom.api/speak"),
            URL(string: "https://custom.api/speak")
        )
    }

    func testDiscoveryIsRefusedWhereItsTransportWouldExposeTheKeyItCarries() {
        // WHY: A discovery request attaches the same bearer credential as a speech request, so it
        // answers to the same transport rule. A refusal is silent by design — no request is created
        // and no list changes — which is why it has to be visible here rather than in a message.
        XCTAssertNil(OpenAIModelDiscovery.url(forSpeechEndpoint: "http://remote.example/v1/audio/speech"))
        XCTAssertNil(OpenAIModelDiscovery.url(forSpeechEndpoint: "ftp://api.example/v1/audio/speech"))
        XCTAssertNil(OpenAIModelDiscovery.url(forSpeechEndpoint: "not a url at all"))
        XCTAssertNil(OpenAIModelDiscovery.url(forSpeechEndpoint: ""))
    }

    func testALocalEngineWithoutACertificateStaysDiscoverable() {
        // WHY: Cleartext to a loopback literal never reaches a network, which is the one case the
        // transport rule permits. Refusing it here would make a local OpenAI-compatible engine's
        // models unreachable while its speech endpoint works.
        XCTAssertEqual(
            OpenAIModelDiscovery.url(forSpeechEndpoint: "http://127.0.0.1:8080/v1/audio/speech"),
            URL(string: "http://127.0.0.1:8080/v1/models")
        )
    }

    func testOnlyTTSModelIdentifiersAreOffered() {
        // WHY: A models list names every model the deployment serves, and the ones that cannot speak
        // would configure a request that fails. Order is the provider's, so it is preserved.
        let payload = Data("""
        {"data": [{"id": "gpt-4o"}, {"id": "tts-1"}, {"id": "whisper-1"}, {"id": "gpt-4o-mini-tts"}]}
        """.utf8)

        XCTAssertEqual(OpenAIModelDiscovery.models(from: payload), ["tts-1", "gpt-4o-mini-tts"])
    }

    func testADeploymentServingNoTTSModelAnswersWithAnEmptyCatalogRatherThanAFailure() {
        // WHY: An endpoint that answered correctly and serves nothing that speaks has published a
        // catalog: an empty one. Reading that as unreadable would leave the previous endpoint's
        // suggestions standing, which is the one thing an invalidated list must not do.
        XCTAssertEqual(OpenAIModelDiscovery.models(from: Data("{\"data\": []}".utf8)), [])
        XCTAssertEqual(OpenAIModelDiscovery.models(from: Data("{\"data\": [{\"id\": \"gpt-4o\"}]}".utf8)), [])
    }

    func testABodyThatIsNotTheDocumentedModelsListIsUnreadableRatherThanEmpty() {
        // WHY: Anything the provider sends can arrive here, and a body this cannot read says nothing
        // about which models exist. Reporting it as an empty catalog would publish that emptiness as
        // the endpoint's answer; reporting it as unreadable abandons the request and keeps the lists.
        for body in [
            "not json at all",
            "",
            "[]",
            "{\"models\": [{\"id\": \"tts-1\"}]}",
            "{\"data\": [{\"name\": \"tts-1\"}]}",
            "{\"data\": {\"id\": \"tts-1\"}}"
        ] {
            XCTAssertNil(
                OpenAIModelDiscovery.models(from: Data(body.utf8)),
                "\(body) is not the documented models list and must not be read as one."
            )
        }
    }
}
