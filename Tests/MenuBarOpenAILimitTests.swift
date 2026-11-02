import XCTest
import AppKit
@testable import ClipboardTTSApp

/// Covers the click-time refusal of OpenAI clipboard text longer than the app's 4,096-character cap.
/// `MenuBarView` and the AppKit controls a hosted menu builds are main-actor isolated, so every
/// test here runs on the main actor.
@MainActor
final class MenuBarOpenAILimitTests: MockURLProtocolTestCase {
    private static let alertTitle = "Copied text is too long"

    private func expectedAlertMessage(characterCount: String) -> String {
        "Clipboard TTS sends OpenAI at most 4,096 characters per request. The copied text is "
            + "\(characterCount) characters. Copy a shorter passage and try again."
    }

    /// Runs the main queue once, so a request start the manager deferred while it was publishing
    /// state has a turn to land.
    private func drainMainQueue() {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }

    /// Reads the request generation once the main queue has stopped advancing it.
    ///
    /// A start the manager deferred because it was publishing state is re-queued onto the main
    /// queue, and the re-queued start may defer again, so sampling after a single drain observes a
    /// duplicate request only sometimes. Draining until two readings agree makes it deterministic.
    private func settledRequestGeneration(of networkManager: TTSNetworkManager) -> UInt64 {
        var previous = networkManager.currentRequestGeneration()
        for _ in 0..<5 {
            drainMainQueue()
            let current = networkManager.currentRequestGeneration()
            if current == previous { return current }
            previous = current
        }
        XCTFail("The request generation never stopped advancing, so no count can be trusted.")
        return previous
    }

    /// Asserts how many logical requests a click started, which no expectation can express.
    ///
    /// The manager advances its request generation once per `streamTTS` call and never on ordinary
    /// completion, so this counts started requests. A mock handler cannot: a duplicate request
    /// replaces the first, whose task may be cancelled before its handler ever runs, which makes a
    /// second fulfilment — and therefore an over-fulfilment failure — depend on timing.
    private func assertRequestsStarted(_ expected: UInt64,
                                       by networkManager: TTSNetworkManager,
                                       from generationBefore: UInt64,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertEqual(
            settledRequestGeneration(of: networkManager) &- generationBefore,
            expected,
            "The click must start exactly \(expected) request(s).",
            file: file,
            line: line
        )
    }

    /// An OpenAI manager whose Realtime connections are scripted, calling `onConnection` as each
    /// request opens one. By default reaching OpenAI fails the test.
    private func makeOpenAIManager(
        onConnection: @escaping @Sendable (ScriptedRealtimeConnection) -> Void = { _ in
            XCTFail("Oversized OpenAI text must not reach the provider.")
        }
    ) -> TTSNetworkManager {
        let connections = ScriptedRealtimeConnections(opened: onConnection)
        addTeardownBlock { connections.all.forEach { $0.cancel() }; connections.drain() }
        let networkManager = TestNetworkFactory.makeManager(realtimeConnections: connections)
        networkManager.updateSettings(
            baseURL: OpenAIRealtimeSpeech.endpoint,
            apiKey: "test",
            model: "gpt-realtime-2.1-mini",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        return networkManager
    }

    func testOversizedOpenAIClipboardTextPresentsTheLimitAlertInsteadOfRequestingSpeech() {
        // WHY: The Speech API documented one 4,096-character maximum for `input`, and the Realtime
        // API that replaced it was kept to that cap because longer speech showed silent gaps. A
        // longer clipboard value must be refused with a reason before a request is spent on it, and
        // the pipeline left idle so the next Speak click needs no Clear Buffer first.
        let audioPlayer = makeOwnedAudioPlayer()
        let pasteboard = FakePasteboardReader(text: String(repeating: "a", count: 4_097))
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = makeOpenAIManager()
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        XCTAssertEqual(pasteboard.readCount, 1, "The refusal judges text the click had already read.")
        XCTAssertEqual(alerts.presentedTitles, [Self.alertTitle])
        XCTAssertEqual(alerts.presentedMessages, [expectedAlertMessage(characterCount: "4,097")])
        XCTAssertFalse(networkManager.isStreaming, "A refused click must start no request.")
        assertRequestsStarted(0, by: networkManager, from: generationBefore)
        XCTAssertFalse(audioPlayer.hasAudio, "A refused click must schedule no audio, so the button stays Speak.")
        XCTAssertNil(
            networkManager.lastError,
            "The pop-up owns this outcome; publishing it too would also render it inline in the menu."
        )
    }

    func testOpenAIClipboardTextAtTheLimitStartsExactlyOneRequest() {
        // WHY: The limit is a maximum, not a threshold to stay under. Refusing text at the cap
        // would block work the user is entitled to, and this boundary is what an off-by-one in
        // either direction moves.
        let audioPlayer = makeOwnedAudioPlayer()
        let pasteboard = FakePasteboardReader(text: String(repeating: "a", count: 4_096))
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let requestStarted = expectation(description: "Text at the limit reaches the provider")
        let networkManager = makeOpenAIManager { _ in requestStarted.fulfill() }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        wait(for: [requestStarted], timeout: 2.0)
        assertRequestsStarted(1, by: networkManager, from: generationBefore)
        XCTAssertTrue(alerts.presentedTitles.isEmpty, "Text within the limit must raise no dialog.")
    }

    func testOpenAILimitRefusesFewerGraphemeClustersWhoseScalarsExceedIt() {
        // WHY: The unit is the whole rule. Swift's default `String.count` counts grapheme clusters,
        // so accented text written as a base letter plus a combining mark reads as half its scalar
        // length: this value is 2,049 clusters but 4,098 code points, which is what the cap,
        // counted in code points, sees. Counting clusters would send it and lose the
        // request the check exists to save.
        let combiningAccentText = String(repeating: "e\u{0301}", count: 2_049)
        XCTAssertEqual(combiningAccentText.count, 2_049, "The value must stay under the limit by cluster count.")
        XCTAssertEqual(combiningAccentText.unicodeScalars.count, 4_098, "It must exceed the limit by scalar count.")
        let audioPlayer = makeOwnedAudioPlayer()
        let pasteboard = FakePasteboardReader(text: combiningAccentText)
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = makeOpenAIManager { _ in XCTFail("Text over the scalar limit must not reach the provider.") }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        XCTAssertEqual(alerts.presentedMessages, [expectedAlertMessage(characterCount: "4,098")])
        XCTAssertFalse(networkManager.isStreaming)
        assertRequestsStarted(0, by: networkManager, from: generationBefore)
    }

    func testOpenAILimitAcceptsScalarsWithinItDespiteMoreUTF16UnitsAndBytes() {
        // WHY: The trade-off of choosing a unit runs both ways. Non-BMP characters cost two UTF-16
        // units and four UTF-8 bytes each, so counting either would refuse this value — 4,096 code
        // points, the exact maximum — and every ordinary non-Latin passage far below the limit. A
        // false refusal blocks work the cap allows, which no later failure can undo.
        let emojiText = String(repeating: "\u{1F600}", count: 4_096)
        XCTAssertEqual(emojiText.unicodeScalars.count, 4_096, "The value must sit exactly at the limit in scalars.")
        XCTAssertEqual(emojiText.utf16.count, 8_192, "It must exceed the limit in UTF-16 units.")
        XCTAssertEqual(emojiText.utf8.count, 16_384, "It must exceed the limit in UTF-8 bytes.")
        let audioPlayer = makeOwnedAudioPlayer()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader(text: emojiText))
        let requestStarted = expectation(description: "Text within the scalar limit reaches the provider")
        let networkManager = makeOpenAIManager { _ in requestStarted.fulfill() }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        wait(for: [requestStarted], timeout: 2.0)
        assertRequestsStarted(1, by: networkManager, from: generationBefore)
        XCTAssertTrue(alerts.presentedTitles.isEmpty, "Only the scalar count may refuse a click.")
    }

    func testOversizedGeminiClipboardTextStillStartsItsRequest() {
        // WHY: The limit is OpenAI's, not the app's. Gemini documents no such maximum, and the
        // user chose a provider-scoped check precisely so Gemini keeps its one-request, fastest
        // path. A guard that read the endpoint instead of the selected provider could refuse here.
        let audioPlayer = makeOwnedAudioPlayer()
        let textExtraction = TextExtractionManager(
            pasteboard: FakePasteboardReader(text: String(repeating: "a", count: 5_000))
        )
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        let requestStarted = expectation(description: "The Gemini request reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        wait(for: [requestStarted], timeout: 2.0)
        assertRequestsStarted(1, by: networkManager, from: generationBefore)
        XCTAssertTrue(alerts.presentedTitles.isEmpty, "Gemini text must not meet OpenAI's limit.")
    }

    func testOversizedCustomClipboardTextStillStartsItsRequest() {
        // WHY: A Custom endpoint's limits belong to whoever runs it, and the default Custom base
        // URL is the same string as OpenAI's fixed endpoint. A check that inferred the provider
        // from the endpoint would silently refuse text a self-hosted service accepts.
        let audioPlayer = makeOwnedAudioPlayer()
        let textExtraction = TextExtractionManager(
            pasteboard: FakePasteboardReader(text: String(repeating: "a", count: 5_000))
        )
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "custom-token",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        let requestStarted = expectation(description: "The Custom request reaches its endpoint")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        wait(for: [requestStarted], timeout: 2.0)
        assertRequestsStarted(1, by: networkManager, from: generationBefore)
        XCTAssertTrue(alerts.presentedTitles.isEmpty, "A Custom endpoint owns its own limits.")
    }

    func testStaleDeferredActionOverTheLimitPresentsNoAlert() {
        // WHY: A dropped attempt speaks for a click the pipeline no longer belongs to, so it must
        // stay silent in every direction: it may neither start speech nor interrupt whatever now
        // owns the pipeline with a modal panel about a clipboard read it never performed.
        let audioPlayer = makeOwnedAudioPlayer()
        let pasteboard = FakePasteboardReader(text: String(repeating: "a", count: 4_097))
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let onlyRequest = expectation(description: "Only the Services request reaches the provider")
        let networkManager = makeOpenAIManager { _ in onlyRequest.fulfill() }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        view.speakCopiedText()

        let center = NotificationCenter()
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center
        )
        withExtendedLifetime(coordinator) {
            center.post(name: ServicesCoordinator.speakSelectedTextNotification, object: "Selected text")
            XCTAssertTrue(networkManager.isStreaming, "The Services request must own the pipeline.")

            deferral.runDeferredActions()

            XCTAssertEqual(pasteboard.readCount, 0, "A stale action reads no clipboard, so it may judge no length.")
            XCTAssertTrue(alerts.presentedTitles.isEmpty, "A stale action must raise no dialog.")
            wait(for: [onlyRequest], timeout: 2.0)
        }
    }
}
