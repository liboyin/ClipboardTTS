import Foundation

/// The values the menu's sliders state to assistive technology such as VoiceOver.
///
/// A slider's number alone says nothing a listener can use: the position slider's is a count of
/// seconds and the speed slider's a bare multiplier. The wording is fixed English, like the rest of
/// the menu, so it does not follow the user's locale, and every function is pure.
enum MenuSpokenValues {
    /// A playback position within the buffered audio, such as "1 minute 5 seconds of 3 minutes".
    static func position(_ progress: Double, of duration: Double) -> String {
        "\(self.duration(progress)) of \(self.duration(duration))"
    }

    /// A length of time as hours, minutes and seconds, leaving out each unit that is zero.
    ///
    /// Part of a second is dropped, as a clock drops it, so the text never names a second that has
    /// not finished. A length that is negative or not finite reads as "0 seconds".
    static func duration(_ seconds: Double) -> String {
        // The two bounds keep the conversion to `Int` defined for any finite input, and the
        // conversion drops the fraction.
        let whole = seconds.isFinite ? Int(min(max(seconds, 0), Double(Int32.max))) : 0
        let parts = [(whole / 3600, "hour"), (whole / 60 % 60, "minute"), (whole % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    /// A playback rate to one decimal place, such as "1.5 times", matching the menu's Speed readout.
    static func speed(_ rate: Float) -> String {
        String(format: "%.1f times", rate)
    }
}
