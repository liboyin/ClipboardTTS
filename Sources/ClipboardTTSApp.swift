import SwiftUI
import AppKit

@main
struct ClipboardTTSApp: App {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var textExtraction = TextExtractionManager()
    @StateObject private var networkManager = TTSNetworkManager()
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        MenuBarExtra("Clipboard TTS", systemImage: "waveform.circle") {
            MenuBarView(
                audioPlayer: audioPlayer,
                textExtraction: textExtraction,
                networkManager: networkManager
            )
        }
        .menuBarExtraStyle(.window)
        
        Window("Settings", id: "settings") {
            SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServicesProvider()
    }
}

class ServicesProvider: NSObject {
    @objc func handleServices(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        if let text = pasteboard.string(forType: .string) {
            NotificationCenter.default.post(name: NSNotification.Name("SpeakSelectedText"), object: text)
        }
    }
}
