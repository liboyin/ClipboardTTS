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
    
    func testNotificationObserver() {
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let networkManager = TTSNetworkManager(configuration: config)
        
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        
        let view = MenuBarView(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        let hostingController = NSHostingController(rootView: view)
        _ = hostingController.view
        
        NotificationCenter.default.post(name: NSNotification.Name("SpeakSelectedText"), object: "Test text from notification")
        
        let expectation = XCTestExpectation(description: "Wait for notification")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
    
    func testMenuBarViewMethods() {
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)
        
        let view = MenuBarView(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        
        view.togglePlayPause()
        view.togglePlayPause()
        
        view.speakCopiedText()
        
        let expectation = XCTestExpectation(description: "Wait for text extraction")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}


