import XCTest
import SwiftUI
import AppKit
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
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        var host: NSHostingView? = NSHostingView(rootView: view)
        host?.frame = NSRect(x: 0, y: 0, width: 600, height: 350)
        host?.layoutSubtreeIfNeeded()

        let suggestionsRendered = expectation(description: "Settings renders its Gemini voice suggestions")
        DispatchQueue.main.async {
            host?.layoutSubtreeIfNeeded()
            XCTAssertEqual(networkManager.availableVoices, documentedGeminiTTSVoices)
            XCTAssertEqual(
                host?.descendantPopUpButtonTitles().filter { $0 == documentedGeminiTTSVoices }.count,
                1,
                "Settings must offer the documented Gemini voices in exactly one suggestion control."
            )
            suggestionsRendered.fulfill()
        }
        wait(for: [suggestionsRendered], timeout: 1.0)

        // The hosted Settings view owns settings observers. Release it and give AppKit a main-queue
        // turn before MockURLProtocol invalidates this test's session, so no deferred observer can
        // start a metadata request after its owner has been torn down.
        host = nil
        let viewGraphReleased = expectation(description: "Hosted Settings view graph is released")
        DispatchQueue.main.async {
            viewGraphReleased.fulfill()
        }
        wait(for: [viewGraphReleased], timeout: 1.0)
    }
}

private extension NSView {
    /// Collects the item titles of every descendant pop-up button, newest suggestion lists included.
    func descendantPopUpButtonTitles() -> [[String]] {
        let ownTitles = (self as? NSPopUpButton).map { [$0.itemTitles] } ?? []
        return ownTitles + subviews.flatMap { $0.descendantPopUpButtonTitles() }
    }
}
