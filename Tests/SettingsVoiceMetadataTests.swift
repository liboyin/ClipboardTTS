import XCTest
@testable import ClipboardTTSApp

/// Covers which suggestions a provider's Settings form may offer and how its selection stays valid.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SettingsVoiceMetadataTests: MockURLProtocolTestCase {
    func testSettingsSuggestsTheCompleteDocumentedGeminiVoiceCatalog() {
        // WHY: Settings is where a user types a voice, and since the menu stopped offering one it is
        // the only surface a documented voice can reach. Offering a subset of the provider contract
        // would put a documented voice out of reach entirely, so this drives the rendered Settings
        // form and reads back the voice suggestions it actually shows.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Gemini"
        ])
        let secretStore = InMemorySecretStore()
        let audioPlayer = makeOwnedAudioPlayer()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(
            settings.suggestionLists().filter { $0 == documentedGeminiTTSVoices }.count,
            1,
            "Settings must offer the documented Gemini voices in exactly one suggestion control."
        )
        settings.release()
    }

    func testACustomFormOffersNoCatalogEvenForAGoogleLookingHost() {
        // WHY: Suggestions follow the provider the form renders, exactly as speech follows the
        // selected identity. A Custom host containing Google's hostname is still Custom, which
        // documents nothing, so offering Gemini's (or any) catalog would suggest choices its endpoint
        // never declared. Rendering no picker must also leave the configured values alone.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://generativelanguage.googleapis.com.custom.example/v1/audio/speech",
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice"
        ])
        let secretStore = InMemorySecretStore()
        let audioPlayer = makeOwnedAudioPlayer()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(settings.suggestionControls(), [], "A Custom form must offer no catalog.")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.customModel), "custom-model")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.customVoice), "custom-voice")
        XCTAssertEqual(networkManager.requestSettingsSnapshot().model, "custom-model")
        XCTAssertEqual(networkManager.requestSettingsSnapshot().voice, "custom-voice")

        // The first assertion holds only if this lookup can see a picker at all: the same hosted
        // form, once its provider offers suggestions, must render one it finds for each row.
        settings.selectProvider("OpenAI")
        XCTAssertEqual(settings.suggestionControls().count, 2, "An OpenAI form must render a visible picker per row.")
        settings.release()
    }

    func testFieldsOfferTheCatalogsOfTheProviderTheyRender() {
        // WHY: A provider switch renders the new provider's fields once before `onChange`
        // resynchronizes the manager, and SwiftUI commits no AppKit state for that render, so a
        // hosted form cannot be read in it. The fields therefore take their choices from the
        // provider they are given and nothing else; rendering them directly for each provider is
        // what states that the render offers that provider's catalogs, whatever the manager holds.
        let geminiFields = HostedModelVoiceFields(
            provider: .gemini,
            model: "gemini-3.8-flash-tts",
            voice: "Puck",
            testCase: self
        )
        XCTAssertEqual(
            geminiFields.suggestionControls(),
            [
                HostedSettings.SuggestionControl(
                    choices: ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"],
                    selection: "gemini-3.8-flash-tts"
                ),
                HostedSettings.SuggestionControl(choices: documentedGeminiTTSVoices, selection: "Puck")
            ]
        )
        geminiFields.release()

        let openAIFields = HostedModelVoiceFields(
            provider: .openAI,
            model: "gpt-realtime-2.1",
            voice: "ash",
            testCase: self
        )
        XCTAssertEqual(
            openAIFields.suggestionControls(),
            [
                HostedSettings.SuggestionControl(
                    choices: ["gpt-realtime-2.1-mini", "gpt-realtime-2.1"],
                    selection: "gpt-realtime-2.1"
                ),
                HostedSettings.SuggestionControl(
                    choices: ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse", "marin", "cedar"],
                    selection: "ash"
                )
            ]
        )
        openAIFields.release()
    }

    func testAFormReRenderedWhileTheManagerHoldsAnotherProviderOffersItsOwnCatalogs() {
        // WHY: A provider switch renders the new provider's form once while the manager still holds
        // the provider it left. A form that took its provider from the manager would offer the old
        // provider's catalogs in exactly that render. SwiftUI commits no AppKit state for it, so this
        // holds the same disagreement still: the form is on Gemini, the manager is pointed at OpenAI
        // directly, and a published manager change re-renders the form without resynchronizing it.
        let defaults = makeOwnedDefaults([SettingsKeys.ttsProvider: "Gemini"])
        let secretStore = InMemorySecretStore()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: makeOwnedAudioPlayer(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )
        networkManager.updateSettings(baseURL: OpenAIRealtimeSpeech.endpoint, apiKey: "", model: "gpt-realtime-2.1-mini",
                                      voice: "alloy", selectedProvider: "OpenAI")

        networkManager.isStreaming = true
        settings.settle()
        let controls = settings.suggestionControls()
        networkManager.isStreaming = false

        XCTAssertEqual(networkManager.requestSettingsSnapshot().provider, .openAI, "The re-render must not resynchronize.")
        XCTAssertEqual(
            controls,
            [
                HostedSettings.SuggestionControl(
                    choices: ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"],
                    selection: "gemini-3.8-flash-lite-tts"
                ),
                HostedSettings.SuggestionControl(choices: documentedGeminiTTSVoices, selection: "Aoede")
            ]
        )
        settings.release()
    }

    func testTypedOffCatalogModelAndVoiceStaySelectedBesideTheDocumentedCatalog() throws {
        // WHY: A model or voice the documented catalog does not list is still the user's choice, so
        // the form must keep each exactly as typed and speak with it, while offering the catalog it
        // can be corrected from. Dropping either from its picker would leave that picker showing no
        // selected item; replacing it with a catalog entry would send a request the user never
        // configured. Both fields are driven because each renders its own picker. The model is the
        // retired 3.1 preview, which users who chose it keep after it left the catalog.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Gemini"
        ])
        let secretStore = InMemorySecretStore()
        try secretStore.saveSecret("test-gemini-api-key", for: .gemini)
        let audioPlayer = makeOwnedAudioPlayer()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)

        let requestEmitted = expectation(description: "Test Voice sends the typed Gemini model and voice")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let url = try XCTUnwrap(request.url?.absoluteString)
            XCTAssertTrue(url.contains("/models/gemini-3.1-flash-tts-preview:"), url)
            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(geminiVoiceName(in: body), "Unlisted-Preview-Voice")
            requestEmitted.fulfill()
            return (response, Data())
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.type("gemini-3.1-flash-tts-preview", into: .providerModel, expecting: "gemini-3.8-flash-lite-tts")
        settings.type("Unlisted-Preview-Voice", into: .providerVoice, expecting: "Aoede")

        XCTAssertEqual(
            settings.suggestionControls(),
            [
                HostedSettings.SuggestionControl(
                    choices: ["gemini-3.1-flash-tts-preview", "gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"],
                    selection: "gemini-3.1-flash-tts-preview"
                ),
                HostedSettings.SuggestionControl(
                    choices: ["Unlisted-Preview-Voice"] + documentedGeminiTTSVoices,
                    selection: "Unlisted-Preview-Voice"
                )
            ]
        )
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.geminiModel), "gemini-3.1-flash-tts-preview")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.geminiVoice), "Unlisted-Preview-Voice")

        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testProviderSwitchOffersOnlyTheNewProviderCatalogWithItsOwnSavedValues() throws {
        // WHY: This is the switch that once rendered Gemini's saved model and voice against OpenAI's
        // still-published lists. Afterwards the form must offer only Gemini's choices, must still
        // show the values saved for Gemini rather than one carried over from the provider it left,
        // and each picker must display its own selection. A catalog is not a selection: opening the
        // form and switching must neither rewrite the saved voice nor change what a request sends,
        // and the saved voice is the catalog's last entry so a reset toward its first is visible.
        let defaults = makeOwnedDefaults([
            SettingsKeys.geminiVoice: "Sulafat"
        ])

        let secretStore = InMemorySecretStore()
        try secretStore.saveSecret("test-gemini-api-key", for: .gemini)
        let audioPlayer = makeOwnedAudioPlayer()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let requestEmitted = expectation(description: "Test Voice sends the voice saved for Gemini")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(geminiVoiceName(in: body), "Sulafat")
            requestEmitted.fulfill()
            return (response, Data())
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(settings.suggestionLists().first, ["gpt-realtime-2.1-mini", "gpt-realtime-2.1"])

        settings.selectProvider("Gemini")

        XCTAssertEqual(
            settings.suggestionControls(),
            [
                HostedSettings.SuggestionControl(
                    choices: ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"],
                    selection: "gemini-3.8-flash-lite-tts"
                ),
                HostedSettings.SuggestionControl(choices: documentedGeminiTTSVoices, selection: "Sulafat")
            ]
        )
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.geminiVoice), "Sulafat")

        settings.click("Test Voice")
        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }
}

/// Reads the voice a Gemini speech request asks for out of its nested request body.
private func geminiVoiceName(in body: [String: Any]) -> String? {
    let generationConfig = body["generationConfig"] as? [String: Any]
    let speechConfig = generationConfig?["speechConfig"] as? [String: Any]
    let voiceConfig = speechConfig?["voiceConfig"] as? [String: Any]
    let prebuiltVoiceConfig = voiceConfig?["prebuiltVoiceConfig"] as? [String: Any]
    return prebuiltVoiceConfig?["voiceName"] as? String
}
