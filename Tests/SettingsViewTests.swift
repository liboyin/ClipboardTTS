import XCTest
import SwiftUI
import AVFoundation
import AppKit
@testable import ClipboardTTSApp

final class SettingsViewTests: MockURLProtocolTestCase {

    func testDefaultBundleAboutMetadataReadsHostedApplicationInfoDictionary() throws {
        // WHY: The shipped About action must use the generated app bundle rather than a test-only
        // metadata source, so changing Info.plist metadata is reflected without source edits.
        let expectedName = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let expectedVersion = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let metadata = BundleAboutMetadata()

        XCTAssertEqual(metadata.applicationName, expectedName)
        XCTAssertEqual(metadata.applicationVersion, expectedVersion)
    }

    func testBundleAboutMetadataReadsNameAndMarketingVersionFromInfoDictionary() {
        // WHY: The standard About panel must receive release metadata from the app bundle, so a
        // source-level version string cannot silently diverge from the packaged Info.plist.
        let metadata = BundleAboutMetadata(bundle: BundleInfoStub(values: [
            "CFBundleName": "Metadata Clipboard TTS",
            "CFBundleShortVersionString": "9.4"
        ]))

        XCTAssertEqual(metadata.applicationName, "Metadata Clipboard TTS")
        XCTAssertEqual(metadata.applicationVersion, "9.4")
    }

    func testSettingsFormExposesAboutButtonThatRoutesToPresenter() throws {
        // WHY: An injected action alone does not prove users can reach About; the rendered form
        // must keep the conventional control and route its click without opening AppKit UI in tests.
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"data\": []}".utf8))
        }
        let presenter = CapturingAboutPanelPresenter()
        let view = SettingsView(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            aboutAction: AboutAction(
                metadata: StaticAboutMetadata(applicationName: "Test Clipboard TTS", applicationVersion: "7.3"),
                presenter: presenter
            )
        )
        var host: NSHostingView? = NSHostingView(rootView: view)
        host?.frame = NSRect(x: 0, y: 0, width: 600, height: 350)

        let buttonRouted = expectation(description: "Settings renders and routes its About button")
        DispatchQueue.main.async {
            guard let host else {
                XCTFail("Settings host must remain available until its About control is routed.")
                buttonRouted.fulfill()
                return
            }
            host.layoutSubtreeIfNeeded()
            guard let button = host.descendantButton(titled: "About Clipboard TTS") else {
                XCTFail("Settings must render an About Clipboard TTS button.")
                buttonRouted.fulfill()
                return
            }
            button.performClick(nil)
            XCTAssertEqual(presenter.presentedApplicationName, "Test Clipboard TTS")
            XCTAssertEqual(presenter.presentedApplicationVersion, "7.3")
            buttonRouted.fulfill()
        }
        wait(for: [buttonRouted], timeout: 1.0)

        // The hosted SwiftUI view owns settings observers. Release it and give AppKit a main-queue
        // turn before MockURLProtocol invalidates this test's session, so no deferred observer can
        // start a metadata request after its owner has been torn down.
        host = nil
        let viewGraphReleased = expectation(description: "Hosted Settings view graph is released")
        DispatchQueue.main.async {
            viewGraphReleased.fulfill()
        }
        wait(for: [viewGraphReleased], timeout: 1.0)
    }

    func testAboutActionPassesInjectedBundleMetadataWithoutPresentingSystemUI() {
        // WHY: The About command must route the bundle's marketing version to macOS's panel, not
        // a second hard-coded string, while tests must never present an interactive AppKit panel.
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let presenter = CapturingAboutPanelPresenter()
        let view = SettingsView(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            aboutAction: AboutAction(
                metadata: StaticAboutMetadata(applicationName: "Test Clipboard TTS", applicationVersion: "7.3"),
                presenter: presenter
            )
        )

        view.showAbout()

        XCTAssertEqual(presenter.presentedApplicationName, "Test Clipboard TTS")
        XCTAssertEqual(presenter.presentedApplicationVersion, "7.3")
    }

    func testStandardAboutPanelOptionsLinkToBundledLicense() throws {
        // WHY: “LICENSE” in About credits must open the exact resource users receive, rather than
        // leaving them with an unresolvable filename inside the app bundle.
        let expectedLicenseURL = try XCTUnwrap(Bundle.main.url(forResource: "LICENSE", withExtension: nil))
        let options = StandardAboutPanelPresenter().aboutPanelOptions(
            applicationName: "Test Clipboard TTS",
            applicationVersion: "7.3"
        )
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        let licenseRange = (credits.string as NSString).range(of: "LICENSE")

        XCTAssertEqual(credits.attribute(.link, at: licenseRange.location, effectiveRange: nil) as? URL, expectedLicenseURL)
    }

    func testCustomSampleRatePersistsAndOtherProvidersResetTo24KHz() {
        // WHY: Only Custom PCM may use a user override. Switching away must reset the live graph
        // to the documented provider format so a later OpenAI or Gemini response is never decoded
        // at the previous Custom rate.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set(48_000.0, forKey: SettingsKeys.customSampleRate)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)

        view.syncSettings()
        XCTAssertEqual(audioPlayer.sampleRate, 48_000)

        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }
        UserDefaults.standard.set("OpenAI", forKey: SettingsKeys.ttsProvider)
        view.providerDidChange(to: "OpenAI")

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
    }

    func testInvalidCustomSampleRateIsReportedWithoutStartingTestVoice() {
        // WHY: The Settings field must refuse invalid PCM rates before a Test Voice request can
        // stream bytes into an unchanged graph, and its established error is rendered inline.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set(48_001.0, forKey: SettingsKeys.customSampleRate)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("An invalid PCM rate must not start Test Voice")
            return (HTTPURLResponse(), Data())
        }

        view.runTestVoice()

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testInvalidCustomSampleRateEditKeepsTheLastKnownGoodPersistedValue() {
        // WHY: A malformed draft must remain visible for correction without becoming startup
        // configuration. Otherwise a relaunch could silently decode Custom PCM at the default rate.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set(24_000.0, forKey: SettingsKeys.customSampleRate)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)

        view.updateCustomSampleRate(from: "48001")

        XCTAssertEqual(UserDefaults.standard.double(forKey: SettingsKeys.customSampleRate), 24_000)
        XCTAssertFalse(audioPlayer.hasValidSampleRateConfiguration)
        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
    }

    func testInvalidCustomSampleRateDraftBlocksTestVoiceAndSubsequentSettingsSync() {
        // WHY: A visible invalid draft must remain the active validation state until corrected.
        // Otherwise a later sync could silently recover the saved 24-kHz graph and speak despite
        // the field still showing a Custom format the app refuses to decode.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("An invalid Custom PCM draft must not start Test Voice")
            return (HTTPURLResponse(), Data())
        }

        view.updateCustomSampleRate(from: "48001")
        view.syncSettings()

        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)

        view.runTestVoice()

        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testTestVoiceDoesNotStartRequestWhenDefaultRateEngineCannotRecover() {
        // WHY: A sample rate can match the selected provider while its graph failed to start.
        // Test Voice must retry that graph and keep its failure visible instead of sending a TTS
        // request that cannot play.
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager(engineStarter: { _ in throw EngineStartFailure.failed })
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("A stopped audio graph must not start Test Voice")
            return (HTTPURLResponse(), Data())
        }

        view.runTestVoice()

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
        XCTAssertEqual(audioPlayer.sampleRateError, "Couldn't start audio playback. Try again.")
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testCustomTestVoiceEmitsConfiguredOpenAICompatiblePayload() {
        // WHY: Test Voice must synchronize persisted Custom settings into the production request
        // path, so an endpoint test proves the same model/voice contract as normal speech.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("test-custom-key", forKey: SettingsKeys.legacyCustomAPIKey)
        UserDefaults.standard.set("https://custom.api/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)
        UserDefaults.standard.set("custom-model", forKey: SettingsKeys.customModel)
        UserDefaults.standard.set("custom-voice", forKey: SettingsKeys.customVoice)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)

        let requestEmitted = expectation(description: "Custom Test Voice request is emitted")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://custom.api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-custom-key")
            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
            XCTAssertEqual(Set(body.keys), ["model", "input", "voice", "response_format"])
            XCTAssertEqual(body["model"], "custom-model")
            XCTAssertEqual(body["voice"], "custom-voice")
            XCTAssertEqual(body["response_format"], "pcm")
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        view.runTestVoice()
        wait(for: [requestEmitted], timeout: 2.0)
    }

    func testCustomTestVoiceRejectsWhitespaceConfigurationWithoutStartingARequest() {
        // WHY: Test Voice must use the same Custom validation as clipboard and Services speech.
        // Otherwise a test action could contact an endpoint with a configuration normal speech
        // correctly rejects, making Settings appear to work while it uses a different contract.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("https://custom.api/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)
        UserDefaults.standard.set("\n\t ", forKey: SettingsKeys.customModel)
        UserDefaults.standard.set("custom-voice", forKey: SettingsKeys.customVoice)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("Invalid Custom Test Voice configuration must not contact the endpoint")
            return (HTTPURLResponse(), Data())
        }

        view.runTestVoice()

        XCTAssertEqual(networkManager.lastError, "Custom TTS requires a model and voice. Update Settings and try again.")
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testCustomTestVoiceRejectsACleartextEndpointWithoutStartingARequest() {
        // WHY: Settings is where the Custom endpoint is typed, so Test Voice is the first action
        // that would send the saved key to it. It must refuse cleartext with the same message and
        // the same no-request outcome as clipboard and Services speech.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("test-custom-key", forKey: SettingsKeys.legacyCustomAPIKey)
        UserDefaults.standard.set("http://custom.api/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)
        UserDefaults.standard.set("custom-model", forKey: SettingsKeys.customModel)
        UserDefaults.standard.set("custom-voice", forKey: SettingsKeys.customVoice)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("A cleartext Custom endpoint must not be contacted")
            return (HTTPURLResponse(), Data())
        }

        view.runTestVoice()

        XCTAssertEqual(
            networkManager.lastError,
            "The TTS endpoint must use HTTPS unless it runs on localhost. Update Settings and try again."
        )
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testProviderDidChangeAndTestVoice() {
        // Isolated even though this test writes nothing: SettingsView reads the provider from
        // UserDefaults.standard, so without it the exercised code path depends on machine state.
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)

        // providerDidChange fetches metadata, so its local handler must be installed before it runs.
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }

        view.providerDidChange(to: "OpenAI")
        view.providerDidChange(to: "Gemini")

        view.runTestVoice()

        // Let async execute
        let expectation = XCTestExpectation(description: "Wait for test voice")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertFalse(networkManager.isStreaming)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}

private enum EngineStartFailure: Error {
    case failed
}

private struct StaticAboutMetadata: AboutMetadataProviding {
    let applicationName: String
    let applicationVersion: String
}

private struct BundleInfoStub: BundleInfoReading {
    let values: [String: Any]

    func object(forInfoDictionaryKey key: String) -> Any? {
        values[key]
    }
}

private final class CapturingAboutPanelPresenter: AboutPanelPresenting {
    private(set) var presentedApplicationName: String?
    private(set) var presentedApplicationVersion: String?

    func showAbout(applicationName: String, applicationVersion: String) {
        presentedApplicationName = applicationName
        presentedApplicationVersion = applicationVersion
    }
}

private extension NSView {
    func descendantButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }
        return subviews.lazy.compactMap { $0.descendantButton(titled: title) }.first
    }
}
