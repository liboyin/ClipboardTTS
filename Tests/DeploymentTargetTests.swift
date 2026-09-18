import XCTest
@testable import ClipboardTTSApp

/// Covers the supported-platform decision D12: the app's minimum macOS is the one its tests run on.
final class DeploymentTargetTests: XCTestCase {
    func testTheAppAndItsTestsShareTheMacOS14Floor() {
        // WHY: Every gate runs the test bundle, so the app's advertised minimum is evidenced only
        // while the two agree. Raising the app alone would drop macOS 14 users with nothing asking
        // for it, and raising only the tests would recreate a floor no gate runs on. Xcode writes
        // each bundle's deployment target into its `LSMinimumSystemVersion`.
        let appMinimum = Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
        let testMinimum = Bundle(for: Self.self).object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String

        XCTAssertEqual(Bundle.main.bundleURL.pathExtension, "app", "The hosted app must be the main bundle.")
        XCTAssertEqual(appMinimum, "14.0")
        XCTAssertEqual(testMinimum, "14.0")
    }
}
