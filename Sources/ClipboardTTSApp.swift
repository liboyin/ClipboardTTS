import SwiftUI
import AppKit

@main
struct ClipboardTTSApp: App {
    @StateObject private var audioPlayer: AudioPlayerManager
    @StateObject private var textExtraction: TextExtractionManager
    @StateObject private var networkManager: TTSNetworkManager

    // Owns the Services-notification subscription for the app's lifetime, so the Services flow
    // works before the menu bar dropdown (and thus MenuBarView) is ever built. Held as a
    // @StateObject (like the managers) so all four share first-wins lifecycle semantics and can
    // never end up pointing at different manager instances.
    @StateObject private var servicesCoordinator: ServicesCoordinator
    private let secretStore: SecretStoring

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let secretStore = KeychainSecretStore()
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager()
        let networkManager = TTSNetworkManager(secretStore: secretStore)
        self.secretStore = secretStore
        _audioPlayer = StateObject(wrappedValue: audioPlayer)
        _textExtraction = StateObject(wrappedValue: textExtraction)
        _networkManager = StateObject(wrappedValue: networkManager)
        _servicesCoordinator = StateObject(wrappedValue: ServicesCoordinator(audioPlayer: audioPlayer, networkManager: networkManager))
    }

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
            SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
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
            NotificationCenter.default.post(name: ServicesCoordinator.speakSelectedTextNotification, object: text)
        }
    }
}
