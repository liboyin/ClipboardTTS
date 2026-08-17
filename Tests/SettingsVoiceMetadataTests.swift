import XCTest
@testable import ClipboardTTSApp

final class SettingsVoiceMetadataTests: MockURLProtocolTestCase {
    func testSettingsSuggestsTheSameDocumentedGeminiVoiceCatalogAsTheMenu() {
        // WHY: Settings is where a user types a voice, so its suggestions are the other surface a
        // documented voice must reach. Publishing the catalog for the menu alone would leave
        // Settings offering a stale subset of the same provider contract, so this drives the
        // rendered Settings form and reads back the voice suggestions it actually shows.
        UserDefaults.standard.set("Gemini", forKey: SettingsKeys.ttsProvider)
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            testCase: self
        )

        XCTAssertEqual(networkManager.availableVoices, documentedGeminiTTSVoices)
        XCTAssertEqual(
            settings.suggestionLists().filter { $0 == documentedGeminiTTSVoices }.count,
            1,
            "Settings must offer the documented Gemini voices in exactly one suggestion control."
        )
        settings.release()
    }
}
