import Foundation
import ApplicationServices
import AppKit

class TextExtractionManager: ObservableObject {
    func getCopiedText() -> String? {
        let pasteboard = NSPasteboard.general
        if let copiedText = pasteboard.string(forType: .string), !copiedText.isEmpty {
            print("TextExtractionManager: Successfully got text from clipboard")
            return copiedText
        }
        print("TextExtractionManager: No text found in clipboard.")
        return nil
    }
}
