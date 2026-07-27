import XCTest
@testable import ClipboardTTSApp

final class UserDefaultsSnapshotTests: XCTestCase {

    func testRestoreReturnsEachKeyToItsCapturedState() {
        // WHY: every settings test in this bundle writes to the real app's defaults domain and
        // relies on restore() undoing it. Both halves matter: a key that had a value must get that
        // value back, and a key that had none must be *removed*, not overwritten with the test's
        // value. Writing instead of removing would silently leak test settings into the app.
        let suiteName = "UserDefaultsSnapshotTests.suite"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("original", forKey: "existing")
        let snapshot = UserDefaultsSnapshot(keys: ["existing", "absent"], defaults: defaults)

        defaults.set("overwritten", forKey: "existing")
        defaults.set("introduced", forKey: "absent")
        snapshot.restore()

        XCTAssertEqual(defaults.string(forKey: "existing"), "original")
        XCTAssertNil(defaults.object(forKey: "absent"))
    }

    func testIsolationClearsEverySettingsKey() {
        // WHY: isolateAppSettingsDefaults() is also what makes settings tests deterministic. If it
        // only snapshotted without clearing, a test reading `ttsProvider` would pick up the
        // developer's machine configuration and pass or fail depending on it.
        //
        // The first call guards the developer's real settings; the planted values then give the
        // second call — the one under test — something to clear on every machine, so this cannot
        // pass vacuously on a fresh checkout. Teardown blocks run in reverse order of
        // registration, so the plants are undone before the originals are put back.
        isolateAppSettingsDefaults()
        for key in SettingsKeys.allUserDefaultsKeys {
            UserDefaults.standard.set("planted-\(key)", forKey: key)
        }

        isolateAppSettingsDefaults()

        for key in SettingsKeys.allUserDefaultsKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) should be cleared")
        }
    }

    func testAllUserDefaultsKeysContainsEachDeclaredKeyExactlyOnce() {
        // WHY: test isolation must clear every persisted setting. Omitting even one newly added
        // key would let that setting leak from a developer's app into tests, or let a test
        // overwrite it permanently.
        let declaredKeys = [
            SettingsKeys.ttsProvider,
            SettingsKeys.apiBaseURL,
            SettingsKeys.openAIModel,
            SettingsKeys.openAIVoice,
            SettingsKeys.geminiModel,
            SettingsKeys.geminiVoice,
            SettingsKeys.legacyOpenAIAPIKey,
            SettingsKeys.legacyGeminiAPIKey,
            SettingsKeys.legacyCustomAPIKey
        ]

        XCTAssertEqual(Set(SettingsKeys.allUserDefaultsKeys), Set(declaredKeys))
        XCTAssertEqual(SettingsKeys.allUserDefaultsKeys.count, declaredKeys.count)
        XCTAssertEqual(Set(SettingsKeys.allUserDefaultsKeys).count, SettingsKeys.allUserDefaultsKeys.count)
    }
}
