import XCTest
@testable import ClipboardTTSApp

// `ProviderDefaults` owns what each surface starts from before anything is stored, but every
// expectation in this file is a literal: a test deriving them from the owner would pass a drifted
// default, which is the regression a fresh install meets.

/// Covers what a fresh Settings form shows for each provider.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so the suite runs on
/// the main actor.
@MainActor
final class ProviderDefaultsSettingsTests: MockURLProtocolTestCase {
    func testAFreshFormShowsEachProvidersDefaultsAndOpensOnOpenAI() {
        // WHY: Before anything is stored, the form must show the values the first request sends. A
        // form fallback drifting from launch resolution would display one model or voice while
        // speech used another.
        let defaults = makeOwnedDefaults()
        let secretStore = InMemorySecretStore()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: makeOwnedAudioPlayer(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        // OpenAI's form is the one a fresh window opens on; Gemini's renders the same two fields,
        // so its distinct values are what tell the two apart.
        XCTAssertEqual(settings.text(in: .providerModel), "gpt-realtime-2.1-mini")
        XCTAssertEqual(settings.text(in: .providerVoice), "alloy")
        XCTAssertNil(defaults.object(forKey: SettingsKeys.ttsProvider), "Opening the form must not store a provider.")

        settings.selectProvider("Gemini")
        XCTAssertEqual(settings.text(in: .providerModel), "gemini-3.8-flash-lite-tts")
        XCTAssertEqual(settings.text(in: .providerVoice), "Aoede")

        settings.selectProvider("Custom")
        XCTAssertEqual(settings.text(in: .customBaseURL), "http://127.0.0.1:8881/v1/audio/speech")
        XCTAssertEqual(settings.text(in: .customModel), "")
        XCTAssertEqual(settings.text(in: .customVoice), "")
        settings.release()
    }
}

/// Covers what a launch configures when no provider is stored.
///
/// A plain `XCTestCase`, like the other startup regressions: the graph is built by
/// `AppStartupDependencies.make`, not by the mock-network factory, and its session refuses every
/// request locally.
final class ProviderDefaultsStartupTests: XCTestCase {
    func testStartupWithNoStoredProviderSpeaksOpenAIAtTheProviderRate() {
        // WHY: A launch with no stored provider must start as OpenAI in both halves it configures:
        // the manager's first request and the player's format. A Custom sample rate left from an
        // earlier configuration is what tells the player's fallback apart, since a fresh Custom
        // rate equals OpenAI's 24 kHz, so it is stored here without a provider.
        let defaults = makeOwnedDefaults([SettingsKeys.customSampleRate: 48_000.0])

        let dependencies = AppStartupDependencies.make(
            isHostedTest: false,
            productionSessionRouting: .refusingEveryRequest,
            productionDefaults: { defaults },
            productionSecretStore: { InMemorySecretStore() }
        )
        defer { dependencies.networkManager.session.invalidateAndCancel() }

        let settings = dependencies.networkManager.requestSettingsSnapshot()
        XCTAssertEqual(settings.provider, .openAI)
        XCTAssertEqual(settings.baseURL, "wss://api.openai.com/v1/realtime")
        XCTAssertEqual(settings.model, "gpt-realtime-2.1-mini")
        XCTAssertEqual(settings.voice, "alloy")
        XCTAssertEqual(dependencies.audioPlayer.sampleRate, 24_000)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.ttsProvider), "Startup must not store a provider.")
    }
}
