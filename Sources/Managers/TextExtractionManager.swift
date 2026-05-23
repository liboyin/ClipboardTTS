import Foundation
import ApplicationServices
import AppKit

class TextExtractionManager: ObservableObject {
    func getSelectedText() -> String? {
        if let axText = getSelectedTextViaAccessibility() {
            return axText
        }
        return getSelectedTextViaClipboard()
    }
    
    private func getSelectedTextViaAccessibility() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard error == .success, let focused = focusedElement else {
            return nil
        }
        
        let axElement = focused as! AXUIElement
        var selectedTextValue: CFTypeRef?
        let textError = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedTextValue)
        
        guard textError == .success, let selectedText = selectedTextValue as? String, !selectedText.isEmpty else {
            return nil
        }
        
        return selectedText
    }
    
    private func getSelectedTextViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)
        
        // Simulate Cmd+C
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let keyC: CGKeyCode = 0x08
        let cmdDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyC, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyC, keyDown: false)
        cmdUp?.flags = .maskCommand
        
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        
        // Wait briefly for clipboard to update
        Thread.sleep(forTimeInterval: 0.1)
        
        if let newText = pasteboard.string(forType: .string), newText != oldString {
            return newText
        }
        return nil
    }
}
