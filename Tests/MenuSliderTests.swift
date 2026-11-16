import XCTest
import AppKit
import SwiftUI
@testable import ClipboardTTSApp

/// Covers what `MenuSlider` itself owns: the value and range it shows, its enabled state, the values
/// its action delivers, that a value published mid-drag waits for the drag to end, and the name and
/// the spoken value it states to assistive technology.
///
/// Sliders are hosted windowlessly, as DESIGN's hosted-view rules require. A user's movement is
/// delivered by setting the slider's value and sending its action, which is what AppKit's tracking
/// loop does on each step of a drag.
@MainActor
final class MenuSliderTests: XCTestCase {
    func testSliderShowsItsValueAndRangeWithoutCallingBack() {
        // WHY: The slider shows playback state the menu publishes. Showing it must not report an
        // edit, or every progress tick would seek and every speed publication would write itself back.
        let slider = HostedSlider(value: 0.25, range: 0.0...2.0, testCase: self)

        XCTAssertEqual(slider.control?.minValue, 0)
        XCTAssertEqual(slider.control?.maxValue, 2)
        XCTAssertEqual(slider.control?.doubleValue, 0.25)
        XCTAssertEqual(slider.control?.isContinuous, true, "A drag must report every change, as SwiftUI's did.")
        XCTAssertEqual(slider.control?.numberOfTickMarks, 0, "An unstepped slider must offer every value.")
        XCTAssertEqual(slider.control?.allowsTickMarkValuesOnly, false)
        XCTAssertEqual(slider.edits, [])
    }

    func testSliderFollowsANewRangeAndValueWithoutCallingBack() {
        // WHY: The position slider's range is the buffered duration, which grows while audio
        // streams in. A range left at its first value would clamp the thumb short of the end.
        let slider = HostedSlider(value: 0.0, range: 0.0...0.01, testCase: self)

        slider.render(value: 3.0, range: 0.0...5.0)

        XCTAssertEqual(slider.control?.maxValue, 5)
        XCTAssertEqual(slider.control?.doubleValue, 3)
        XCTAssertEqual(slider.edits, [])
    }

    func testSliderFollowsTheDisabledEnvironment() {
        // WHY: The menu disables the position slider while nothing is buffered, through SwiftUI's
        // `.disabled`. An AppKit control does not see that modifier unless it reads the environment.
        let slider = HostedSlider(value: 0.0, range: 0.0...1.0, isDisabled: true, testCase: self)
        XCTAssertEqual(slider.control?.isEnabled, false)

        slider.render(value: 0.0, range: 0.0...1.0, isDisabled: false)
        XCTAssertEqual(slider.control?.isEnabled, true)
    }

    func testMovingAnUnsteppedSliderDeliversItsExactPosition() {
        // WHY: The position slider seeks to wherever it is dragged; rounding the position would
        // move playback somewhere the user did not put it.
        let slider = HostedSlider(value: 0.0, range: 0.0...2.0, testCase: self)

        slider.move(to: 0.375)
        slider.move(to: 1.2)

        XCTAssertEqual(slider.edits, [0.375, 1.2])
    }

    func testMovingTheSpeedSliderDeliversSwiftUIsStepValues() {
        // WHY: The speed slider replaced `Slider(value:in:0.5...2.5, step: 0.1)` over a `Float`,
        // which on macOS 27 wrote `0.5 + n * 0.1` computed in `Float`. Three of those (1.4, 1.8 and
        // 2.3) are not the nearest `Float` to the decimal, so arithmetic in `Double` would change
        // the rate the player is given. Positions between steps must land on the nearest step.
        let slider = HostedStepSlider(value: 1.0, testCase: self)
        XCTAssertEqual(slider.control?.numberOfTickMarks, 21, "SwiftUI marks every selectable value.")
        XCTAssertEqual(slider.control?.allowsTickMarkValuesOnly, true, "The thumb must stop only on a step.")

        for step in 0...20 {
            slider.move(to: 0.5 + Double(step) * 0.1 + (step.isMultiple(of: 2) ? 0.04 : -0.04))
        }

        let expected = (0...20).map { Float(0.5) + Float($0) * Float(0.1) }
        XCTAssertEqual(slider.edits, expected)
        XCTAssertEqual(slider.edits[9], 1.4000001)
        XCTAssertNotEqual(slider.edits[9], Float(1.4))
    }

    func testSteppedValuesStayWithinTheRange() {
        // WHY: A position past either end must deliver that end, not a step outside the range.
        XCTAssertEqual(MenuSlider<Float>.steppedValue(at: 9.0, in: 0.5...2.5, step: 0.1), 2.5)
        XCTAssertEqual(MenuSlider<Float>.steppedValue(at: -1.0, in: 0.5...2.5, step: 0.1), 0.5)
        XCTAssertEqual(MenuSlider<Float>.stepCount(in: 0.5...2.5, step: 0.1), 20)
    }

    func testAValuePublishedDuringADragWaitsUntilTheDragEnds() {
        // WHY: While the user drags, the position slider's own seeks and the playback timer keep
        // publishing new values. Applying one mid-drag would pull the thumb away from the pointer;
        // applying none afterwards would leave the thumb where the drag left it rather than where
        // playback is.
        let slider = HostedSlider(value: 0.25, range: 0.0...2.0, testCase: self)
        guard let control = slider.control else { return XCTFail("The slider must render.") }

        control.beginTracking()
        control.doubleValue = 1.0
        slider.render(value: 1.6, range: 0.0...2.0)
        XCTAssertEqual(control.doubleValue, 1.0, "A published value must not move the thumb mid-drag.")

        control.endTracking()
        XCTAssertEqual(control.doubleValue, 1.6, "The latest published value must apply once the drag ends.")
        XCTAssertEqual(slider.edits, [])
    }

    func testSliderStatesItsNameAndDescribesTheValueItShows() {
        // WHY: A bare `NSSlider` announces only a number. The slider must carry the name it was
        // given, and describe its value through the formatter it was given, or VoiceOver cannot
        // say what the control is or what its position means.
        let slider = HostedSlider(value: 0.25, range: 0.0...2.0, testCase: self)

        XCTAssertEqual(slider.control?.accessibilityLabel(), "Test position")
        XCTAssertEqual(slider.control?.accessibilityValueDescription(), "value 0.25")

        slider.render(value: 1.5, range: 0.0...2.0, label: "Renamed", spokenValue: { "now \($0)" })

        XCTAssertEqual(slider.control?.accessibilityLabel(), "Renamed", "A new render's name must replace the old one.")
        XCTAssertEqual(slider.control?.accessibilityValueDescription(), "now 1.5")
    }

    func testSliderDescribesWhereTheThumbIsWithoutANewRender() {
        // WHY: Each step of a drag moves the thumb before any render follows it, and a value
        // published mid-drag is held back. A description fixed at render time would then state a
        // position the thumb has left.
        let slider = HostedSlider(value: 0.25, range: 0.0...2.0, testCase: self)
        guard let control = slider.control else { return XCTFail("The slider must render.") }

        control.beginTracking()
        control.doubleValue = 1.0
        slider.render(value: 1.6, range: 0.0...2.0)

        XCTAssertEqual(control.accessibilityValueDescription(), "value 1.0", "The description must follow the thumb.")
        control.endTracking()
        XCTAssertEqual(control.accessibilityValueDescription(), "value 1.6")
    }

    func testASteppedSliderDescribesTheStepItWouldDeliver() {
        // WHY: Between steps, the stepped slider delivers the nearest step. Describing the raw
        // position instead would state a rate the player is never given.
        let slider = HostedStepSlider(value: 1.0, testCase: self)
        guard let control = slider.control else { return XCTFail("The slider must render.") }
        XCTAssertEqual(control.accessibilityValueDescription(), "step 1.0")

        control.doubleValue = 1.43

        XCTAssertEqual(control.accessibilityValueDescription(), "step \(Float(0.5) + Float(9) * Float(0.1))")
    }

    func testADragWithNoPublishedValueLeavesTheThumbWhereItWasReleased() {
        // WHY: Ending a drag must not move the thumb by itself; only a value published during the
        // drag may replace where the user left it.
        let slider = HostedSlider(value: 0.25, range: 0.0...2.0, testCase: self)
        guard let control = slider.control else { return XCTFail("The slider must render.") }

        control.beginTracking()
        control.doubleValue = 1.0
        control.endTracking()

        XCTAssertEqual(control.doubleValue, 1.0)
    }
}

/// Covers the menu's own wiring of its two sliders to the audio player.
///
/// `MenuBarView` and the AppKit controls a hosted menu builds are main-actor isolated.
@MainActor
final class MenuBarSliderTests: MockURLProtocolTestCase {
    func testPositionSliderSeeksTheBufferedAudio() {
        // WHY: Dragging the position slider is how a user moves playback. Its action must reach the
        // player's seek, which is what moves playback and republishes the position, over the range
        // the buffered audio spans.
        let publications = AudioStateUpdateRecorder()
        let audioPlayer = makeOwnedAudioPlayer(audioStateObserver: publications.record)
        let published = publications.expectNextUpdate()
        let generation = audioPlayer.startNewStream()
        audioPlayer.scheduleAudio(data: Data(repeating: 0, count: 48_000), streamGeneration: generation) // 1 s
        wait(for: [published], timeout: 1.0)
        let menu = HostedMenu(audioPlayer: audioPlayer, testCase: self)
        guard let position = menu.positionSlider else { return XCTFail("The menu must render a position slider.") }

        XCTAssertEqual(position.maxValue, 1.0)
        XCTAssertTrue(position.isEnabled)

        position.doubleValue = 0.25
        position.sendAction(position.action, to: position.target)

        XCTAssertEqual(audioPlayer.playbackProgress, 0.25, accuracy: 0.000_001)
    }

    func testPositionSliderFollowsTheBufferAndIsDisabledWithoutAudio() {
        // WHY: With nothing buffered there is nothing to seek, so the slider must be disabled over
        // its minimal range; as audio arrives it must become usable over the duration it spans.
        let audioPlayer = makeOwnedAudioPlayer()
        let menu = HostedMenu(audioPlayer: audioPlayer, testCase: self)
        guard let position = menu.positionSlider, let speed = menu.speedSlider else {
            return XCTFail("The menu must render both sliders.")
        }
        XCTAssertFalse(position.isEnabled)
        XCTAssertEqual(position.maxValue, 0.01)
        XCTAssertTrue(speed.isEnabled, "Speed can be set before anything plays.")

        // Set the published state directly, as the menu's other view tests do, so no live audio runs.
        audioPlayer.hasAudio = true
        audioPlayer.bufferDuration = 3.5
        menu.settle()

        XCTAssertTrue(position.isEnabled)
        XCTAssertEqual(position.maxValue, 3.5)
    }

    func testMenuSlidersStateWhatTheyControlAndTheirValuesInWords() {
        // WHY: The menu shows no label for the position slider, and the Speed text beside the
        // other is a separate view. Each slider must say which it is, the position as a time
        // within the buffered audio, and the speed as a multiplier.
        let audioPlayer = makeOwnedAudioPlayer()
        let menu = HostedMenu(audioPlayer: audioPlayer, testCase: self)
        guard let position = menu.positionSlider, let speed = menu.speedSlider else {
            return XCTFail("The menu must render both sliders.")
        }
        XCTAssertEqual(position.accessibilityLabel(), "Playback position")
        XCTAssertEqual(speed.accessibilityLabel(), "Playback speed")
        XCTAssertEqual(position.accessibilityValueDescription(), "0 seconds of 0 seconds")
        XCTAssertEqual(speed.accessibilityValueDescription(), "1.0 times")

        // Set the published state directly, as the menu's other view tests do, so no live audio runs.
        audioPlayer.hasAudio = true
        audioPlayer.bufferDuration = 200
        audioPlayer.playbackProgress = 65.4
        audioPlayer.playbackRate = 1.5
        menu.settle()

        XCTAssertEqual(position.accessibilityValueDescription(), "1 minute 5 seconds of 3 minutes 20 seconds")
        XCTAssertEqual(speed.accessibilityValueDescription(), "1.5 times")
    }

    func testSpeedSliderSetsThePlaybackRateToTheNearestStep() {
        // WHY: The speed slider is the only control for the player's rate, which the Speed readout
        // beside it shows. Its action must set that rate to the step SwiftUI's slider would have.
        let audioPlayer = makeOwnedAudioPlayer()
        let menu = HostedMenu(audioPlayer: audioPlayer, testCase: self)
        guard let speed = menu.speedSlider else { return XCTFail("The menu must render a speed slider.") }
        XCTAssertEqual(speed.minValue, 0.5)
        XCTAssertEqual(speed.maxValue, 2.5)
        XCTAssertEqual(speed.doubleValue, 1.0)

        speed.doubleValue = 1.43
        speed.sendAction(speed.action, to: speed.target)

        XCTAssertEqual(audioPlayer.playbackRate, Float(0.5) + Float(9) * Float(0.1))
    }
}

/// Hosts one unstepped `MenuSlider<Double>` and records each value it delivers.
@MainActor
private final class HostedSlider {
    private var host: NSHostingView<AnyView>?
    private(set) var edits: [Double] = []

    var control: DragDeferringSlider? {
        host?.descendants(of: DragDeferringSlider.self).first
    }

    init(value: Double, range: ClosedRange<Double>, isDisabled: Bool = false, testCase: XCTestCase) {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        host?.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        testCase.addTeardownBlock {
            self.host = nil
            drainHostedMainQueue(file: #filePath, line: #line)
        }
        render(value: value, range: range, isDisabled: isDisabled)
    }

    func render(value: Double,
                range: ClosedRange<Double>,
                isDisabled: Bool = false,
                label: String = "Test position",
                spokenValue: @escaping (Double) -> String = { "value \($0)" }) {
        host?.rootView = AnyView(
            MenuSlider(
                value: value,
                range: range,
                accessibilityLabel: label,
                spokenValue: spokenValue,
                onEdit: { self.edits.append($0) }
            )
            .disabled(isDisabled)
        )
        settleHostedView(host, file: #filePath, line: #line)
    }

    /// Moves the slider to `position` the way one step of a drag does.
    func move(to position: Double) {
        guard let control else { return XCTFail("The slider must render.") }
        control.doubleValue = position
        control.sendAction(control.action, to: control.target)
    }
}

/// Hosts the speed slider's configuration, a `Float` over `0.5...2.5` in steps of 0.1.
@MainActor
private final class HostedStepSlider {
    private var host: NSHostingView<MenuSlider<Float>>?
    private(set) var edits: [Float] = []

    var control: DragDeferringSlider? {
        host?.descendants(of: DragDeferringSlider.self).first
    }

    init(value: Float, testCase: XCTestCase) {
        let host = NSHostingView(
            rootView: MenuSlider<Float>(
                value: value,
                range: 0.5...2.5,
                step: 0.1,
                accessibilityLabel: "Test speed",
                spokenValue: { "step \($0)" },
                onEdit: { self.edits.append($0) }
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        self.host = host
        testCase.addTeardownBlock {
            self.host = nil
            drainHostedMainQueue(file: #filePath, line: #line)
        }
        settleHostedView(host, file: #filePath, line: #line)
    }

    func move(to position: Double) {
        guard let control else { return XCTFail("The slider must render.") }
        control.doubleValue = position
        control.sendAction(control.action, to: control.target)
    }
}

/// Hosts the menu over an owned player and finds its two sliders, position first, as it renders them.
@MainActor
private final class HostedMenu {
    private var host: NSHostingView<MenuBarView>?

    var positionSlider: DragDeferringSlider? { sliders.first }
    var speedSlider: DragDeferringSlider? { sliders.count == 2 ? sliders[1] : nil }

    private var sliders: [DragDeferringSlider] {
        host?.descendants(of: DragDeferringSlider.self) ?? []
    }

    init(audioPlayer: AudioPlayerManager, testCase: XCTestCase) {
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: TextExtractionManager(pasteboard: FakePasteboardReader()),
            networkManager: TestNetworkFactory.makeManager()
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 280)
        self.host = host
        testCase.addTeardownBlock {
            self.host = nil
            drainHostedMainQueue(file: #filePath, line: #line)
        }
        settle()
    }

    func settle() {
        settleHostedView(host, file: #filePath, line: #line)
    }
}
