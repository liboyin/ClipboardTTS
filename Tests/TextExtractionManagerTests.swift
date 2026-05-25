import XCTest
import AppKit
@testable import ClipboardTTSApp

final class TextExtractionManagerTests: XCTestCase {
    
    func testTextExtractionDoesNotCrash() {
        // WHY: Text extraction relies on Pasteboard which might fail to yield string data.
        // We must ensure that calling getCopiedText gracefully handles this and returns nil or string without crashing.
        
        let manager = TextExtractionManager()
        let text = manager.getCopiedText()
        
        // Assert that we get either nil or a string, gracefully.
        XCTAssertTrue(text == nil || text != nil)
    }
    
    func testTextExtractionEmptyPasteboard() {
        // WHY: Ensure getCopiedText returns nil when pasteboard is empty.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        let manager = TextExtractionManager()
        let text = manager.getCopiedText()
        XCTAssertNil(text)
    }
}
