import AppKit
import SwiftUI

/// A continuous AppKit slider for one of the menu's playback values.
///
/// The menu renders its sliders through AppKit rather than `Slider` for the reason
/// `SuggestionPicker` gives: from macOS 27 SwiftUI draws a slider itself, leaving a hosted test no
/// control to find (D36).
///
/// Moving the slider passes its value to `onEdit` on every change during a drag, as SwiftUI's
/// slider wrote its binding; nothing else calls `onEdit`, so updating the view never echoes `value`
/// back. The slider honours `.disabled` through the environment and follows `range` as it changes.
///
/// Every slider states what it controls and what its value means to assistive technology: a bare
/// `NSSlider` announces only a number, and the text beside it in the menu is a separate view.
struct MenuSlider<Value: BinaryFloatingPoint>: NSViewRepresentable where Value.Stride: BinaryFloatingPoint {
    let value: Value
    let range: ClosedRange<Value>
    /// The distance between selectable values, or `nil` for any value in `range`.
    var step: Value.Stride?
    /// What the slider controls, as assistive technology names it. It has no default, so no slider
    /// can be left unnamed.
    let accessibilityLabel: String
    /// States a value the slider can hold in words, such as a time or a multiplier.
    let spokenValue: (Value) -> String
    let onEdit: (Value) -> Void

    func makeCoordinator() -> MenuSliderCoordinator {
        MenuSliderCoordinator()
    }

    func makeNSView(context: Context) -> DragDeferringSlider {
        let slider = DragDeferringSlider(
            value: 0,
            minValue: 0,
            maxValue: 1,
            target: context.coordinator,
            action: #selector(MenuSliderCoordinator.slide(_:))
        )
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: DragDeferringSlider, context: Context) {
        let range = range
        let step = step
        let onEdit = onEdit
        let spokenValue = spokenValue
        // The value a thumb position stands for, which is what an edit delivers and what is spoken.
        let valueAt: (Double) -> Value = { position in
            guard let step else { return Value(position) }
            return Self.steppedValue(at: position, in: range, step: step)
        }
        context.coordinator.deliver = { onEdit(valueAt($0)) }
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.spokenValue = { spokenValue(valueAt($0)) }
        slider.isEnabled = context.environment.isEnabled
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        // Tick marks are what make AppKit snap the thumb to a step, and SwiftUI's stepped slider
        // draws one per selectable value on macOS 27 as well.
        let stepCount = step.map { Self.stepCount(in: range, step: $0) }
        slider.numberOfTickMarks = stepCount.map { $0 + 1 } ?? 0
        slider.allowsTickMarkValuesOnly = stepCount != nil
        slider.show(Double(value))
    }

    /// The number of whole steps from `range`'s lower bound that stay within it.
    static func stepCount(in range: ClosedRange<Value>, step: Value.Stride) -> Int {
        let length = Double(range.lowerBound.distance(to: range.upperBound))
        // Rounding to the nearest whole step absorbs the representation error of a decimal step:
        // `Float(0.1)` divides `2.0` into 19.9999997 steps, and 0.5...2.5 must still reach 2.5.
        return max(0, Int((length / Double(step)).rounded()))
    }

    /// The selectable value nearest the slider's `position`, computed in `Value`'s own arithmetic as
    /// `lowerBound + n * step`.
    ///
    /// That arithmetic is SwiftUI's: on macOS 27, `Slider(value:in:step:)` over a `Float` binding
    /// wrote exactly `Float(0.5) + Float(n) * Float(0.1)` for every step of `0.5...2.5`, which differs
    /// from the nearest `Float` to the decimal value at 1.4, 1.8, and 2.3.
    static func steppedValue(at position: Double, in range: ClosedRange<Value>, step: Value.Stride) -> Value {
        let steps = ((position - Double(range.lowerBound)) / Double(step)).rounded()
        let clampedSteps = min(max(steps, 0), Double(stepCount(in: range, step: step)))
        return range.lowerBound.advanced(by: Value.Stride(clampedSteps) * step)
    }
}

/// Receives a `MenuSlider`'s actions, which `updateNSView` keeps pointed at the latest `onEdit`.
///
/// It is not generic, unlike the slider it serves, so that the Objective-C action selector it
/// exposes needs no generic class. AppKit sends its action on the main thread, where the slider it
/// reads lives.
@MainActor
final class MenuSliderCoordinator: NSObject {
    var deliver: (Double) -> Void = { _ in }

    @objc func slide(_ sender: NSSlider) {
        deliver(sender.doubleValue)
    }
}

/// An `NSSlider` that does not move its thumb to a value published while the user is dragging it,
/// and that describes its value in words.
///
/// A drag's actions publish new values, and the position slider's value also advances on the
/// playback timer, so an update arriving mid-drag would pull the thumb away from the pointer.
/// `NSSlider.mouseDown(with:)` runs AppKit's tracking loop and returns only when the mouse is
/// released, so it brackets the drag exactly; the latest value published inside it is applied when
/// it returns.
final class DragDeferringSlider: NSSlider {
    private(set) var isTracking = false
    private var deferredValue: Double?
    /// States a thumb position in words; `MenuSlider` supplies it on every update.
    var spokenValue: ((Double) -> String)?

    /// Describes the position the thumb is at now, so the description cannot lag behind a value
    /// that changed without a new render, such as one step of a drag.
    override func accessibilityValueDescription() -> String? {
        spokenValue?(doubleValue) ?? super.accessibilityValueDescription()
    }

    override func mouseDown(with event: NSEvent) {
        beginTracking()
        defer { endTracking() }
        super.mouseDown(with: event)
    }

    /// Shows `newValue`, or holds it until the drag in progress ends.
    func show(_ newValue: Double) {
        if isTracking {
            deferredValue = newValue
        } else {
            doubleValue = newValue
        }
    }

    /// Starts deferring published values; `mouseDown(with:)` calls it as a drag begins.
    func beginTracking() {
        isTracking = true
    }

    /// Stops deferring and shows the latest value published during the drag, if any.
    func endTracking() {
        isTracking = false
        if let deferredValue {
            self.deferredValue = nil
            doubleValue = deferredValue
        }
    }
}
