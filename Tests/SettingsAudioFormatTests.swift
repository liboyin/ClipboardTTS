import XCTest
@testable import ClipboardTTSApp

/// Covers the Settings edits that replace the live PCM format while a request is still streaming
/// into it, and the session each one has to end.
///
/// The form reaches the audio graph by two routes — the Custom sample-rate field, and the
/// synchronization every other edit runs — so each is driven here. Hosted Settings drives
/// `NSHostingView` and the AppKit controls it builds, so every test runs on the main actor.
@MainActor
final class SettingsAudioFormatTests: MockURLProtocolTestCase {

    func testOpeningCustomSettingsPreservesFractionalSampleRateAcrossReopen() {
        // WHY: Mounting Settings synchronizes the visible draft into the audio graph and persisted
        // configuration. Rounding the draft there silently changes the next request's PCM format
        // and invokes the live-format cancellation policy even though the user changed nothing.
        let sampleRate = 24_000.4
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.customSampleRate: sampleRate
        ])
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("Opening a Custom Settings form must not request metadata.")
            return (HTTPURLResponse(), Data())
        }

        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(settings.text(in: .customSampleRate), "24000.4")
        XCTAssertEqual(defaults.double(forKey: SettingsKeys.customSampleRate), sampleRate)
        XCTAssertEqual(audioPlayer.sampleRate, sampleRate)
        // A later ordinary Settings synchronization must read the preserved draft rather than
        // rounding it after SwiftUI has committed the initial state.
        settings.type("custom-model", into: .customModel, expecting: "")
        XCTAssertEqual(defaults.double(forKey: SettingsKeys.customSampleRate), sampleRate)
        XCTAssertEqual(audioPlayer.sampleRate, sampleRate)
        settings.release()

        let reopenedSettings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(reopenedSettings.text(in: .customSampleRate), "24000.4")
        XCTAssertEqual(defaults.double(forKey: SettingsKeys.customSampleRate), sampleRate)
        XCTAssertEqual(audioPlayer.sampleRate, sampleRate)
        reopenedSettings.release()
    }

    func testEditingTheCustomSampleRateCancelsTheRequestItInvalidates() {
        // WHY: This is the Settings half of NB9, on the route that changes a format most often.
        // Typing a rate the graph accepts discards the PCM already decoded at the old one; the
        // request still delivering that PCM has to end with it, or it streams audio the player is
        // now certain to drop while the menu keeps offering to clear an empty buffer.
        let owned = makeCustomProviderSettings()
        let releaseResponse = DispatchSemaphore(value: 0)
        startHeldTestVoice(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }

        owned.settings.type("48000", into: .customSampleRate, expecting: "24000")

        XCTAssertNil(
            owned.networkManager.activeTaskForTesting,
            "A rate the field applies must cancel the request feeding the audio it discards."
        )
        XCTAssertFalse(owned.networkManager.isStreaming)
        XCTAssertEqual(owned.audioPlayer.sampleRate, 48_000)
        owned.settings.release()
    }

    func testSwitchingProviderCancelsTheRequestTheResetFormatInvalidates() {
        // WHY: Leaving Custom resets the graph to the fixed 24-kHz provider format, which is the
        // same discard by a different route: the form's synchronization rather than its sample-rate
        // field. A revert on either route alone would leave the other looking correct.
        let owned = makeCustomProviderSettings(customSampleRate: 48_000)
        XCTAssertEqual(owned.audioPlayer.sampleRate, 48_000, "The mounted form must apply the saved Custom rate.")
        let releaseResponse = DispatchSemaphore(value: 0)
        startHeldTestVoice(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }

        owned.settings.selectProvider("OpenAI")

        XCTAssertNil(
            owned.networkManager.activeTaskForTesting,
            "Resetting the format on a provider switch must cancel the request feeding the audio it discards."
        )
        XCTAssertFalse(owned.networkManager.isStreaming)
        XCTAssertEqual(owned.audioPlayer.sampleRate, AudioPlayerManager.defaultSampleRate)
        owned.settings.release()
    }

    func testEditingAnUnrelatedCustomFieldLeavesTheRequestStreaming() {
        // WHY: Every Settings edit synchronizes the audio format, and all but a rate change name
        // the rate already active. Cancelling on those would stop speech the user never asked to
        // stop — typing one character of a model name would silence the sample they are listening
        // to — and no mixed-format PCM can exist when the graph did not change.
        let owned = makeCustomProviderSettings()
        let releaseResponse = DispatchSemaphore(value: 0)
        startHeldTestVoice(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }

        owned.settings.type("custom-model-2", into: .customModel, expecting: "custom-model")

        XCTAssertNotNil(
            owned.networkManager.activeTaskForTesting,
            "An edit that changes no format must leave the request that owns the pipeline running."
        )
        XCTAssertTrue(owned.networkManager.isStreaming)
        XCTAssertEqual(owned.audioPlayer.sampleRate, AudioPlayerManager.defaultSampleRate)
        owned.settings.release()
    }

    // MARK: - Support

    /// The Custom endpoint these tests configure, which is the request Test Voice holds open.
    private static let speechEndpoint = "https://custom.api/v1/audio/speech"

    /// A mounted Custom form over the manager pair its own session owner drives.
    private struct OwnedSettings {
        let audioPlayer: AudioPlayerManager
        let networkManager: TTSNetworkManager
        let settings: HostedSettings
    }

    /// Speaks the Test Voice sample and leaves its request in flight until `releaseResponse`.
    ///
    /// A completed response would leave every request assertion in these tests passing for a reason
    /// the format change had nothing to do with. No PCM is delivered, so nothing here schedules
    /// automatic playback or a progress timer the test would then own.
    private func startHeldTestVoice(_ owned: OwnedSettings, releasedBy releaseResponse: DispatchSemaphore) {
        let requestStarted = expectation(description: "Test Voice reaches the provider")
        let speechEndpoint = Self.speechEndpoint
        MockURLProtocol.installRequestHandler { request in
            guard request.url?.absoluteString == speechEndpoint else {
                // Model discovery, which a switch away from Custom asks for. Answering it at once
                // leaves the held speech request as the only one still in flight.
                return (mockHTTPResponse(for: request, statusCode: 200), Data("{ \"data\": [] }".utf8))
            }
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }

        owned.settings.click("Test Voice")

        wait(for: [requestStarted], timeout: 2.0)
        XCTAssertTrue(
            owned.networkManager.isStreaming,
            "The held request must own the pipeline before the format changes."
        )
    }

    /// Mounts Settings on a Custom provider whose Test Voice can reach the mock endpoint.
    private func makeCustomProviderSettings(
        customSampleRate: Double = AudioPlayerManager.defaultSampleRate
    ) -> OwnedSettings {
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: "test-custom-key",
            SettingsKeys.apiBaseURL: Self.speechEndpoint,
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice",
            SettingsKeys.customSampleRate: customSampleRate
        ])
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        // Mounting synchronizes the saved settings; a Custom form asks for no model or voice
        // discovery, so nothing is requested until Test Voice is pressed.
        MockURLProtocol.installRequestHandler { request in
            XCTFail("Mounting a Custom form must request nothing.")
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )
        return OwnedSettings(audioPlayer: audioPlayer, networkManager: networkManager, settings: settings)
    }
}
