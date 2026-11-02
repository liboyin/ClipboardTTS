import XCTest
import AppKit
import SwiftUI
@testable import ClipboardTTSApp

/// Records the alerts a menu action asked for, instead of activating the app and running a modal.
///
/// Confined to the main queue, like the menu flow whose presenter it replaces. The conformance sits
/// in an extension so the recorder itself stays unisolated and a test can still build one from a
/// synchronous test method, while `presentAlert` keeps the protocol's main-actor contract.
final class RecordingMenuAlertPresenter {
    private(set) var presentedTitles: [String] = []
    private(set) var presentedMessages: [String] = []
}

extension RecordingMenuAlertPresenter: MenuAlertPresenting {
    func presentAlert(title: String, message: String) {
        presentedTitles.append(title)
        presentedMessages.append(message)
    }
}

/// Builds the menu with its own deferred-action owner, session owner, and alert recorder unless a
/// test needs to control one. The alert presenter never defaults to the production one, so no test
/// can raise a modal panel that nothing would dismiss.
///
/// `speechSession` defaults to a session owner over the very managers this menu was handed, which
/// is the pairing production wires; a test states its own only to observe what the menu starts.
@MainActor
func makeMenu(audioPlayer: AudioPlayerManager,
              textExtraction: TextExtractionManager,
              networkManager: TTSNetworkManager,
              deferredClipboardAction: DeferredClipboardAction = DeferredClipboardAction(),
              speechSession: SpeechSessionCoordinator? = nil,
              alertPresenter: MenuAlertPresenting = RecordingMenuAlertPresenter()) -> MenuBarView {
    MenuBarView(
        audioPlayer: audioPlayer,
        textExtraction: textExtraction,
        networkManager: networkManager,
        deferredClipboardAction: deferredClipboardAction,
        speechSession: speechSession
            ?? SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
        alertPresenter: alertPresenter
    )
}

/// `MenuBarView` and the AppKit controls a hosted menu builds are main-actor isolated, so every
/// test here runs on the main actor.
@MainActor
final class MenuBarViewTests: MockURLProtocolTestCase {
    func testMenuNeitherShowsAVoiceControlNorFetchesTheCatalogItWouldNeed() {
        // WHY: Voice belongs to Settings alone, so the menu must not become a second place the same
        // setting is read or written. Two mechanisms could reintroduce it and neither is visible
        // from the other: a picker could offer the voice again, and the metadata lookup that fed the
        // old picker could remain, issuing a provider request on every menu open for a catalog
        // nothing displays. The playback controls must survive both removals.
        //
        // Scope, so the next reader does not over-trust this: a windowless host backs a picker with
        // a real NSPopUpButton but draws a plain `Text` itself, publishing no NSTextField and no
        // accessibility tree — the same reason `SettingsActionButton` and `RequestErrorView` exist.
        // A decorative voice *label* is therefore not reachable from any hosted assertion here, and
        // was deliberately not asserted rather than asserted in a way no mutant could break. What is
        // covered is what could actually restore the feature: an offered control, and the fetch.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Gemini",
            SettingsKeys.geminiVoice: "Distinctive-Review-Voice"
        ])
        let audioPlayer = makeOwnedAudioPlayer()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager(defaults: defaults)
        networkManager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Distinctive-Review-Voice",
            selectedProvider: "Gemini"
        )
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        var host: NSHostingView? = NSHostingView(rootView: view)
        host?.frame = NSRect(x: 0, y: 0, width: 300, height: 320)
        host?.layoutSubtreeIfNeeded()

        // Metadata used to publish on the turn after appearance, so a fetch that survived would
        // land here rather than in the first layout.
        let settled = expectation(description: "Menu completes the turn an appearance lookup would publish on")
        DispatchQueue.main.async {
            host?.layoutSubtreeIfNeeded()
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)

        XCTAssertNil(host?.descendantView(of: NSPopUpButton.self), "The menu must offer no voice picker.")
        XCTAssertEqual(
            networkManager.voiceSuggestions,
            ProviderSuggestions.unpublished,
            "Appearing must not fetch a voice catalog the menu no longer shows."
        )
        XCTAssertNotNil(host?.descendantView(of: NSSlider.self), "Playback controls must survive the removal.")

        host = nil
        let viewGraphReleased = expectation(description: "Hosted menu view graph is released")
        DispatchQueue.main.async {
            viewGraphReleased.fulfill()
        }
        wait(for: [viewGraphReleased], timeout: 1.0)
    }

    func testSpeakCopiedTextStartsStreamingFromClipboard() {
        // WHY: This is the core "Speak Copied Text" story - with text on the clipboard and nothing
        // playing, the button must pull the clipboard text and start a network request. Audio
        // scheduling is covered by AudioPlayerManagerTests, so this view test avoids live audio.
        let audioPlayer = makeOwnedAudioPlayer()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader(text: "Speak me"))
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "Custom")
        let requestStarted = expectation(description: "Clipboard text starts a TTS request")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        view.speakCopiedText()

        // speakCopiedText defers clipboard extraction and request creation by 0.2 seconds.
        wait(for: [requestStarted], timeout: 2.0)
    }

    func testSpeakCopiedTextClearsActiveBuffer() {
        // WHY: Once audio is buffered the button becomes "Clear Buffer"; speakCopiedText must then
        // tear playback down (stop streaming + discard buffered audio) rather than start a new read.
        // If it didn't, the button would advertise a clear that never happens.
        let audioPlayer = makeOwnedAudioPlayer()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)

        networkManager.updateSettings(
            baseURL: "not a valid endpoint",
            apiKey: "fake-key",
            model: "test",
            voice: "test",
            selectedProvider: "Custom"
        )
        networkManager.streamTTS(text: "Create an error before clearing") { _ in }
        XCTAssertNotNil(networkManager.lastError)

        // Set the view's branch condition without scheduling live AVAudioEngine work. Audio
        // scheduling is covered by AudioPlayerManagerTests; this test owns only menu behavior.
        audioPlayer.hasAudio = true

        view.speakCopiedText()

        let cleared = XCTestExpectation(description: "Buffer cleared")
        DispatchQueue.main.async {
            XCTAssertFalse(audioPlayer.hasAudio)
            XCTAssertNil(networkManager.lastError)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 1.0)
    }

    func testRenderedErrorMessageAppearsAfterNetworkFailureWithoutRemovingControls() {
        // WHY: The request error is supplementary feedback, not a replacement for playback
        // controls. Mounting the view verifies SwiftUI actually renders the conditional message
        // while keeping the primary playback control available.
        let audioPlayer = makeOwnedAudioPlayer()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 280)

        host.layoutSubtreeIfNeeded()
        let errorMessage = "TTS configuration is invalid. Check the API endpoint and try again."
        XCTAssertNil(host.descendantText(equalTo: errorMessage))
        XCTAssertNotNil(host.descendantView(of: NSSlider.self))

        networkManager.updateSettings(
            baseURL: "not a valid endpoint",
            apiKey: "fake-key",
            model: "test",
            voice: "test",
            selectedProvider: "Custom"
        )
        networkManager.streamTTS(text: "Show error") { _ in }

        let rendered = expectation(description: "Error message rendered")
        DispatchQueue.main.async {
            host.layoutSubtreeIfNeeded()
            XCTAssertNotNil(host.descendantText(equalTo: errorMessage))
            XCTAssertNotNil(host.descendantView(of: NSSlider.self))
            rendered.fulfill()
        }
        wait(for: [rendered], timeout: 1.0)
    }

    func testRenderedErrorMessageWrapsToShowEveryLineWithinTheMenuWidth() {
        // WHY: Most request errors are longer than one line of the menu. The menu window takes its
        // content's fitting size, so the label must report the height its text needs at the width
        // it is given; a label sized for its unwrapped text keeps one line's height and clips the
        // rest, which is what hides the corrective advice the message ends with.
        let audioPlayer = makeOwnedAudioPlayer()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        let host = NSHostingView(rootView: view)

        networkManager.updateSettings(
            baseURL: "not a valid endpoint",
            apiKey: "fake-key",
            model: "test",
            voice: "test",
            selectedProvider: "Custom"
        )
        networkManager.streamTTS(text: "Show a long error") { _ in }

        let errorMessage = "TTS configuration is invalid. Check the API endpoint and try again."
        let rendered = expectation(description: "Error message laid out at the menu's fitting size")
        DispatchQueue.main.async {
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            defer { rendered.fulfill() }
            guard let label = host.descendantText(equalTo: errorMessage) else {
                return XCTFail("The request error must be rendered.")
            }
            let frame = label.convert(label.bounds, to: host)
            XCTAssertLessThanOrEqual(frame.maxX, host.bounds.width, "The label must stay within the menu width.")
            let singleLine = label.cell!.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
            ))
            let wrapped = label.cell!.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: frame.width, height: CGFloat.greatestFiniteMagnitude
            ))
            XCTAssertGreaterThan(wrapped.height, singleLine.height, "This message must need more than one line.")
            XCTAssertGreaterThanOrEqual(frame.height, wrapped.height, "Every wrapped line must be visible.")
        }
        wait(for: [rendered], timeout: 1.0)
    }

    func testRequestErrorWithNoOfferedWidthKeepsItsUnwrappedSingleLineSize() {
        // WHY: Wrapping needs a width to wrap at. When SwiftUI asks for the label's ideal size it
        // offers none, and the label must then answer with its text on one line, as its intrinsic
        // size does, rather than inventing a width and reporting a narrow, needlessly tall column.
        let message = "TTS configuration is invalid. Check the API endpoint and try again."
        let host = NSHostingView(rootView: RequestErrorView(message: message).fixedSize())
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()

        guard let label = host.descendantText(equalTo: message) else {
            return XCTFail("The request error must be rendered.")
        }
        let unwrapped = label.intrinsicContentSize
        XCTAssertGreaterThanOrEqual(label.frame.width, unwrapped.width, "The text must not be wrapped.")
        XCTAssertEqual(label.frame.height, unwrapped.height, "The label must stay one line tall.")
    }

    func testShortRequestErrorStillSpansTheOfferedWidth() {
        // WHY: Before the label wrapped, it spanned the width the menu offered even when its message
        // fit on one line, so the text started at the same leading edge as the controls above it.
        // Sizing for wrapping must not shrink a short message to its text, which would let the
        // menu's centered stack move it away from that edge.
        let message = "Speech request failed (HTTP 500)."
        let offeredWidth: CGFloat = 268
        let host = NSHostingView(rootView: RequestErrorView(message: message).frame(width: offeredWidth))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()

        guard let label = host.descendantText(equalTo: message) else {
            return XCTFail("The request error must be rendered.")
        }
        let frame = label.convert(label.bounds, to: host)
        XCTAssertLessThan(label.cell!.cellSize.width, offeredWidth, "This message must fit on one line.")
        // SwiftUI places a representable by its alignment rect, which for a text field excludes
        // 2-point side insets, so the offered width is the alignment rect's rather than the frame's.
        XCTAssertEqual(label.alignmentRect(forFrame: frame).width, offeredWidth, "The label must span the width.")
        XCTAssertEqual(frame.height, ceil(label.cell!.cellSize.height), "The label must stay one line tall.")
    }

    func testRequestErrorSizeWithAnUnboundedWidthIsItsOneLineSize() {
        // WHY: SwiftUI can offer an infinite width as well as none, and no hosted layout here does.
        // Reporting that width back would be an invalid size, so an unbounded offer must measure
        // the text on one line exactly as an absent one does.
        let cell = NSTextField(wrappingLabelWithString: "TTS configuration is invalid. Check the API endpoint.").cell!

        XCTAssertEqual(RequestErrorView.size(of: cell, wrappedAt: .infinity), cell.cellSize)
        XCTAssertEqual(RequestErrorView.size(of: cell, wrappedAt: nil), cell.cellSize)
    }

}

private extension NSView {
    func descendantText(equalTo value: String) -> NSTextField? {
        if let textField = self as? NSTextField, textField.stringValue == value {
            return textField
        }
        return subviews.lazy.compactMap { $0.descendantText(equalTo: value) }.first
    }

    func descendantView<ViewType: NSView>(of type: ViewType.Type) -> ViewType? {
        if let view = self as? ViewType {
            return view
        }
        return subviews.lazy.compactMap { $0.descendantView(of: type) }.first
    }
}
