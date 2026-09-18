import XCTest
@testable import ClipboardTTSApp

/// Covers when the Settings form's change observers run: an edit must reach future requests, and
/// opening the window must not replay an edit nobody made.
///
/// SwiftUI's `onChange` can also run its action for the initial value. The form relies on it not
/// doing so, because mounting already synchronizes once from `onAppear`. Hosted Settings drives
/// `NSHostingView` and the AppKit controls it builds, so every test runs on the main actor.
@MainActor
final class SettingsChangeObservationTests: MockURLProtocolTestCase {
    private static let speechEndpoint = "https://custom.api/v1/audio/speech"

    func testEditingTheCustomEndpointReachesFutureRequests() {
        // WHY: A clipboard or Services request reads the manager's settings, not the form. An
        // endpoint edit that never reached the manager would keep sending speech — and the user's
        // key — to the address the user just replaced.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: Self.speechEndpoint
        ])
        let secretStore = InMemorySecretStore()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: AudioPlayerManager(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.type("https://replacement.api/v1/audio/speech", into: .customBaseURL, expecting: Self.speechEndpoint)

        XCTAssertEqual(networkManager.requestSettingsSnapshot().baseURL, "https://replacement.api/v1/audio/speech")
        settings.release()
    }

    func testOpeningSettingsDiscoversMetadataOnce() {
        // WHY: Model discovery is a provider request authorized with the user's key. Opening the
        // window synchronizes once; replaying the provider observer as well would spend a second
        // request on lists the first one is already fetching.
        let defaults = makeOwnedDefaults([SettingsKeys.ttsProvider: "OpenAI"])
        let secretStore = InMemorySecretStore()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { request in
            metadataResponse(for: request, json: "{ \"data\": [] }")
        }
        let begun = metadataRequestsBegun(by: networkManager)

        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: AudioPlayerManager(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(
            metadataRequestsBegun(by: networkManager) - begun,
            2,
            "Opening Settings must discover models and publish the voice catalog once each."
        )
        settings.release()
    }

    func testOpeningCustomSettingsNeverReportsTheSavedRateAsInvalid() {
        // WHY: The saved rate is valid and opening the window does not edit it. Replaying the
        // sample-rate observer before the draft is filled in would judge an empty draft, publishing
        // an unusable format the menu refuses to speak with — even if the saved rate replaces it
        // within the same mount.
        let defaults = makeOwnedDefaults([SettingsKeys.ttsProvider: "Custom"])
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let published = LockedValue<[Bool]>([])
        let observation = audioPlayer.$hasValidSampleRateConfiguration.dropFirst().sink { isValid in
            published.withValue { $0.append(isValid) }
        }
        defer { observation.cancel() }

        let settings = HostedSettings(
            networkManager: TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults),
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertFalse(published.value.contains(false), "Opening Settings published an invalid format: \(published.value)")
        XCTAssertTrue(audioPlayer.hasValidSampleRateConfiguration)
        settings.release()
    }

    func testOpeningCustomSettingsLeavesSpeechAlreadyInFlightStreaming() {
        // WHY: Opening the window is not a format change. Mounting fills the rate draft from the
        // saved rate and synchronizes it into the audio graph, and a real format change cancels the
        // request speaking into it. A draft that did not reproduce the saved rate exactly — a
        // fractional one is the case that can drift — would silence clipboard speech the user
        // started from the menu merely by looking at Settings.
        let savedRate = 24_000.4
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: Self.speechEndpoint,
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice",
            SettingsKeys.customSampleRate: savedRate
        ])
        let secretStore = InMemorySecretStore()
        // Startup builds the player at the saved Custom rate, so speech is already in that format.
        let audioPlayer = AudioPlayerManager(sampleRate: savedRate)
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let releaseResponse = DispatchSemaphore(value: 0)
        defer { releaseResponse.signal() }
        let requestStarted = expectation(description: "Menu speech reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }
        SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager)
            .start(text: "Speech started from the menu before Settings opened")
        wait(for: [requestStarted], timeout: 2.0)

        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertNotNil(networkManager.activeTaskForTesting, "Opening Settings must not cancel speech in flight.")
        XCTAssertTrue(networkManager.isStreaming)
        XCTAssertEqual(audioPlayer.sampleRate, savedRate)
        XCTAssertNil(audioPlayer.sampleRateError)
        settings.release()
    }
}
