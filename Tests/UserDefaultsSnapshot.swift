import Foundation
import XCTest

/// Restores a set of `UserDefaults` keys to the exact state they were in when captured.
struct UserDefaultsSnapshot {
    private let defaults: UserDefaults
    private let present: [String: Any]
    private let absent: [String]

    init(keys: [String], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var present: [String: Any] = [:]
        var absent: [String] = []
        for key in keys {
            if let value = defaults.object(forKey: key) {
                present[key] = value
            } else {
                absent.append(key)
            }
        }
        self.present = present
        self.absent = absent
    }

    /// Keys that held a value get it back; keys that held none are removed rather than written,
    /// so nothing the caller wrote in between survives.
    func restore() {
        for (key, value) in present {
            defaults.set(value, forKey: key)
        }
        for key in absent {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Every `UserDefaults.standard` key the app persists settings under: the `@AppStorage`
/// properties of `SettingsView`, which `TTSNetworkManager.init` reads back.
enum AppSettingsDefaults {
    static let keys = [
        "ttsProvider", "apiBaseURL",
        "apiKey", "geminiAPIKey", "customAPIKey",
        "openaiModel", "openaiVoice",
        "geminiModel", "geminiVoice"
    ]
}

extension XCTestCase {
    /// Detaches the running test from the developer's real app settings.
    ///
    /// WHY: the unit-test bundle is hosted inside the app, so `UserDefaults.standard` here *is* the
    /// app's own defaults domain. A test that writes `ttsProvider` reconfigures the installed app
    /// for good, and a test that reads settings otherwise inherits whatever the developer happened
    /// to have configured. Clearing the keys up front makes each test start from the values
    /// declared in code; the teardown block puts the developer's configuration back.
    ///
    /// Trade-off: a test that crashes the process (rather than merely failing) skips its teardown,
    /// so the cleared keys stay cleared. Losing settings to a crash is preferable to silently
    /// running every test against machine state.
    func isolateAppSettingsDefaults() {
        let snapshot = UserDefaultsSnapshot(keys: AppSettingsDefaults.keys)
        addTeardownBlock { snapshot.restore() }
        for key in AppSettingsDefaults.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
