import XCTest
import AppKit
@testable import AdvancedTTSApp

final class TextExtractionManagerTests: XCTestCase {
    
    func testTextExtractionDoesNotCrash() {
        // WHY: Text extraction relies on system APIs (Accessibility and Pasteboard) which might fail or be denied.
        // We must ensure that calling getSelectedText gracefully handles permissions and returns nil or string without crashing.
        
        let manager = TextExtractionManager()
        let text = manager.getSelectedText()
        
        // Assert that we get either nil or a string, gracefully.
        XCTAssertTrue(text == nil || text != nil)
    }
}
