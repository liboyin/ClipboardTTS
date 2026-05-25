import XCTest
import SwiftUI
@testable import ClipboardTTSApp

final class SettingsViewTests: XCTestCase {
    
    func testSettingsViewBody() {
        // WHY: Check that the settings view can be evaluated without crashing.
        let audioPlayer = AudioPlayerManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)
        
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)
        
        let body = view.body
        XCTAssertNotNil(body)
    }
}
