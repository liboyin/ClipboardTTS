import XCTest
@testable import ClipboardTTSApp

final class TextExtractionManagerTests: XCTestCase {

    func testTextExtractionReturnsInjectedPasteboardText() {
        // WHY: The "Speak Copied Text" flow depends on getCopiedText() handing back exactly what
        // the configured pasteboard reader reports. If the manager bypassed that dependency for
        // NSPasteboard.general, this deterministic fake value would not be returned.
        let manager = TextExtractionManager(pasteboard: FakePasteboardReader(text: "Hello clipboard"))
        XCTAssertEqual(manager.getCopiedText(), "Hello clipboard")
    }

    func testTextExtractionEmptyPasteboard() {
        // WHY: Ensure getCopiedText returns nil when pasteboard is empty.
        let manager = TextExtractionManager(pasteboard: FakePasteboardReader())
        let text = manager.getCopiedText()
        XCTAssertNil(text)
    }
}
