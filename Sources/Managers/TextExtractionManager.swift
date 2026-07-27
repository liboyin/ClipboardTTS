import Foundation
import ApplicationServices
import AppKit

/// Reads string values from a pasteboard without exposing mutable pasteboard operations.
protocol PasteboardReading {
    /// Returns the string associated with the requested pasteboard type, when one is available.
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
}

/// Reads from the user's shared macOS pasteboard for the production clipboard flow.
struct GeneralPasteboardReader: PasteboardReading {
    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        NSPasteboard.general.string(forType: dataType)
    }
}

/// Extracts copied text through an injected read-only pasteboard dependency.
final class TextExtractionManager: ObservableObject {
    private let pasteboard: PasteboardReading

    init(pasteboard: PasteboardReading = GeneralPasteboardReader()) {
        self.pasteboard = pasteboard
    }

    func getCopiedText() -> String? {
        if let copiedText = pasteboard.string(forType: .string), !copiedText.isEmpty {
            print("TextExtractionManager: Successfully got text from clipboard")
            return copiedText
        }
        print("TextExtractionManager: No text found in clipboard.")
        return nil
    }
}
