import XCTest
@testable import ClipboardTTSApp

/// Covers the text the menu's sliders state to VoiceOver in place of a bare number.
final class MenuSpokenValuesTests: XCTestCase {
    func testDurationNamesEachNonZeroUnitWithItsPlural() {
        // WHY: A listener hears this text instead of a count of seconds, so each unit must be
        // named, in the singular for one, and a unit that is zero must not be read out.
        XCTAssertEqual(MenuSpokenValues.duration(0), "0 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(1), "1 second")
        XCTAssertEqual(MenuSpokenValues.duration(59), "59 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(60), "1 minute")
        XCTAssertEqual(MenuSpokenValues.duration(61), "1 minute 1 second")
        XCTAssertEqual(MenuSpokenValues.duration(125), "2 minutes 5 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(3600), "1 hour")
        XCTAssertEqual(MenuSpokenValues.duration(3723), "1 hour 2 minutes 3 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(7260), "2 hours 1 minute")
    }

    func testDurationDropsAnUnfinishedSecondAndReadsUnusableLengthsAsZero() {
        // WHY: Playback positions are fractional. Rounding up would name a second that has not
        // played, and a negative or non-finite length must still produce text, not a crash.
        XCTAssertEqual(MenuSpokenValues.duration(0.99), "0 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(59.99), "59 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(-5), "0 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(.nan), "0 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(.infinity), "0 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(-.infinity), "0 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(-.greatestFiniteMagnitude), "0 seconds")
        XCTAssertEqual(MenuSpokenValues.duration(.greatestFiniteMagnitude), "596523 hours 14 minutes 7 seconds")
    }

    func testPositionStatesWhereIsPlayingWithinWhatIsBuffered() {
        // WHY: The position slider's range grows while audio streams in, so a position means
        // nothing without the length it lies within.
        XCTAssertEqual(MenuSpokenValues.position(65.4, of: 200), "1 minute 5 seconds of 3 minutes 20 seconds")
        XCTAssertEqual(MenuSpokenValues.position(0, of: 0), "0 seconds of 0 seconds")
    }

    func testSpeedStatesTheRateToOneDecimalAsAMultiplier() {
        // WHY: The Speed readout beside the slider shows one decimal. The spoken rate must agree
        // with it, including for the stepped values that are not the nearest `Float` to a decimal.
        XCTAssertEqual(MenuSpokenValues.speed(1.0), "1.0 times")
        XCTAssertEqual(MenuSpokenValues.speed(Float(0.5) + Float(9) * Float(0.1)), "1.4 times")
        XCTAssertEqual(MenuSpokenValues.speed(2.5), "2.5 times")
    }
}
