import XCTest
import SwiftUI
@testable import ClipboardTTSApp

final class MenuBarViewTests: XCTestCase {
    
    func testMenuBarViewBody() {
        // WHY: SwiftUI Views are inherently difficult to unit test fully without UI tests,
        // but evaluating the `.body` ensures that there are no fatal errors in view construction.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)
        
        let view = MenuBarView(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        
        // Access body to trigger view construction and improve basic coverage
        let body = view.body
        XCTAssertNotNil(body)
    }
}
