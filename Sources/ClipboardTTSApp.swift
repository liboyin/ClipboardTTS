import SwiftUI
import AppKit

/// Identifies XCTest's hosted app process without importing XCTest into the production target.
enum HostedTestProcess {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }
}

/// The dependencies that must be created before the app scene owns its manager instances.
///
/// The hosted XCTest app is initialized before individual test setup. It therefore receives a
/// fresh defaults suite and in-memory secrets so no startup initializer can access, migrate, or
/// delete a developer's configuration before the test's own isolation lifecycle starts.
struct AppStartupDependencies {
    let defaults: UserDefaults
    let secretStore: SecretStoring
    let audioPlayer: AudioPlayerManager
    let textExtraction: TextExtractionManager
    let networkManager: TTSNetworkManager
    let servicesCoordinator: ServicesCoordinator

    /// Builds production dependencies or an entirely test-owned hosted-test dependency graph.
    static func make(
        isHostedTest: Bool = HostedTestProcess.isActive,
        productionDefaults: () -> UserDefaults = { .standard },
        productionSecretStore: () -> SecretStoring = { KeychainSecretStore() },
        testDefaults: () -> UserDefaults = { UserDefaults(suiteName: "com.clipboardtts.hosted-tests.\(UUID().uuidString)")! },
        testSecretStore: () -> SecretStoring = { InMemorySecretStore() }
    ) -> AppStartupDependencies {
        let defaults: UserDefaults
        let secretStore: SecretStoring
        if isHostedTest {
            defaults = testDefaults()
            secretStore = testSecretStore()
        } else {
            defaults = productionDefaults()
            secretStore = productionSecretStore()
        }

        let persistedProvider = APIKeyProvider(
            selectedProvider: defaults.string(forKey: SettingsKeys.ttsProvider) ?? "OpenAI"
        )
        let persistedCustomSampleRate: Double
        if let storedSampleRate = defaults.object(forKey: SettingsKeys.customSampleRate) {
            persistedCustomSampleRate = storedSampleRate as? Double ?? .nan
        } else {
            persistedCustomSampleRate = AudioPlayerManager.defaultSampleRate
        }
        let initialSampleRate = persistedProvider == .custom
            ? persistedCustomSampleRate
            : AudioPlayerManager.defaultSampleRate
        let audioPlayer = AudioPlayerManager(sampleRate: initialSampleRate)
        let networkManager = TTSNetworkManager(secretStore: secretStore, defaults: defaults)

        return AppStartupDependencies(
            defaults: defaults,
            secretStore: secretStore,
            audioPlayer: audioPlayer,
            textExtraction: TextExtractionManager(),
            networkManager: networkManager,
            servicesCoordinator: ServicesCoordinator(audioPlayer: audioPlayer, networkManager: networkManager)
        )
    }
}

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

    // Owns the menu's pending deferred clipboard read for the app's lifetime. A @StateObject for
    // the same reason as the managers: SwiftUI rebuilds the MenuBarExtra content on every publish,
    // and a per-view instance could not drop an attempt an earlier view value scheduled.
    @StateObject private var deferredClipboardAction = DeferredClipboardAction()
    private let secretStore: SecretStoring

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let dependencies = AppStartupDependencies.make()
        self.secretStore = dependencies.secretStore
        _audioPlayer = StateObject(wrappedValue: dependencies.audioPlayer)
        _textExtraction = StateObject(wrappedValue: dependencies.textExtraction)
        _networkManager = StateObject(wrappedValue: dependencies.networkManager)
        _servicesCoordinator = StateObject(wrappedValue: dependencies.servicesCoordinator)
    }

    var body: some Scene {
        MenuBarExtra("Clipboard TTS", systemImage: "waveform.circle") {
            MenuBarView(
                audioPlayer: audioPlayer,
                textExtraction: textExtraction,
                networkManager: networkManager,
                deferredClipboardAction: deferredClipboardAction
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
