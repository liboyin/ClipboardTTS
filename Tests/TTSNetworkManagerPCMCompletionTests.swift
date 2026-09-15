import XCTest
@testable import ClipboardTTSApp

/// Completion behavior for raw 16-bit PCM received through the two provider transports.
final class TTSNetworkManagerPCMCompletionTests: MockURLProtocolTestCase {
    func testGeminiResponseWithACompleteFrameAndTrailingByteSucceeds() {
        // WHY: Gemini holds incomplete PCM between events and delivers only whole frames. A final
        // orphaned byte must not retroactively fail the frame the user can already hear.
        let manager = TestNetworkFactory.makeManager()
        let deliveredAudio = LockedValue<[Data]>([])
        configureGemini(manager)
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.geminiEvent(audio: Data([0, 1, 2])))
        }

        assertTerminalState(of: manager, expectedError: nil) {
            manager.streamTTS(text: "Test trailing Gemini PCM") { data in
                deliveredAudio.withValue { $0.append(data) }
            }
        }
        drainAudioDelivery(of: manager)

        XCTAssertEqual(deliveredAudio.value, [Data([0, 1])])
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(manager.isStreaming)
    }

    func testOpenAICompatibleResponsesKeepACompleteFrameBeforeTrailingPartialBytes() {
        // WHY: OpenAI and Custom both request 16-bit PCM. They must keep a frame when a final byte
        // cannot form the next one; requiring total parity loses audible PCM the player accepts.
        let providers = [
            (baseURL: "https://mock.api/v1/audio/speech", selectedProvider: "OpenAI"),
            (baseURL: "https://custom.api/v1/audio/speech", selectedProvider: "Custom")
        ]
        let cases = [Data([0, 1]), Data([0, 1, 2])]
        for provider in providers {
            for payload in cases {
                let manager = TestNetworkFactory.makeManager()
                let deliveredAudio = LockedValue<[Data]>([])
                manager.updateSettings(
                    baseURL: provider.baseURL,
                    apiKey: "fake-key",
                    model: "test",
                    voice: "test",
                    selectedProvider: provider.selectedProvider
                )
                MockURLProtocol.installRequestHandler { request in
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, payload)
                }

                assertTerminalState(of: manager, expectedError: nil) {
                    manager.streamTTS(text: "Test PCM completion") { data in
                        deliveredAudio.withValue { $0.append(data) }
                    }
                }
                drainAudioDelivery(of: manager)

                XCTAssertEqual(
                    deliveredAudio.value,
                    [payload],
                    "\(provider.selectedProvider) must only deliver payloads containing a complete PCM frame."
                )
                XCTAssertNil(manager.lastError)
                XCTAssertFalse(manager.isStreaming)
            }
        }
    }

    private func configureGemini(_ manager: TTSNetworkManager) {
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "fake-key",
            model: "gemini-test",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
    }

    private static func geminiEvent(audio: Data) -> Data {
        let prefix = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\""
        let suffix = "\"}}]}}]}\r\n\r\n"
        return Data("\(prefix)\(audio.base64EncodedString())\(suffix)".utf8)
    }

    /// Waits until every callback that this request queued has run before inspecting the log.
    private func drainAudioDelivery(of manager: TTSNetworkManager) {
        let drained = expectation(description: "Queued PCM callbacks have run")
        manager.audioDeliveryQueue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }
}
