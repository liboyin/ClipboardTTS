import XCTest
import AppKit
@testable import ClipboardTTSApp

final class TextExtractionManagerTests: XCTestCase {

    func testTextExtractionReturnsClipboardText() {
        // WHY: The "Speak Copied Text" flow depends on getCopiedText() handing back exactly what
        // the user copied. If it dropped or mangled the clipboard string, the wrong text (or none)
        // would be spoken. Writing a known string and asserting it round-trips guards that contract.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Hello clipboard", forType: .string)

        let manager = TextExtractionManager()
        XCTAssertEqual(manager.getCopiedText(), "Hello clipboard")
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
