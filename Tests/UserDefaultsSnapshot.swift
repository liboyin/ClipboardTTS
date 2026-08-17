import Foundation
import XCTest
@testable import ClipboardTTSApp

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

/// `UserDefaults` storage that lives only for its owning test, backed by memory instead of a suite.
///
/// Overrides the three primitive accessors that `UserDefaults` derives its typed accessors from.
/// A path under test that needs an accessor built on something else must override it here too;
/// `testStartupRegressionDefaultsWriteNeitherToDiskNorToTheAppSettingsDomain` fails when a value
/// falls through to the inherited storage instead.
final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
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
        let snapshot = UserDefaultsSnapshot(keys: SettingsKeys.allUserDefaultsKeys)
        addTeardownBlock { snapshot.restore() }
        for key in SettingsKeys.allUserDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
