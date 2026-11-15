import Foundation
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
///
/// A plain value rather than an observable object: it publishes nothing and holds only its reader,
/// so any copy reads the same pasteboard and SwiftUI has no lifetime to manage for it.
struct TextExtractionManager {
    private let pasteboard: PasteboardReading

    init(pasteboard: PasteboardReading = GeneralPasteboardReader()) {
        self.pasteboard = pasteboard
    }

    func getCopiedText() -> String? {
        if let copiedText = pasteboard.string(forType: .string), !copiedText.isEmpty {
            return copiedText
        }
        return nil
    }
}
