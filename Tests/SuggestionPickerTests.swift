import XCTest
import AppKit
import SwiftUI
@testable import ClipboardTTSApp

/// Covers what `SuggestionPicker` itself owns: which items its pop-up button offers, which one it
/// shows, and that only a user's choice writes the binding.
///
/// The picker is hosted windowlessly, as DESIGN's hosted-view rules require, and each update is
/// delivered by replacing the host's root view, which runs `updateNSView` the way a SwiftUI
/// re-render does. No test here builds a network manager, so the suite needs no mock network scope.
@MainActor
final class SuggestionPickerTests: XCTestCase {
    func testPickerOffersEveryChoiceInOrderWithTheBoundValueSelected() {
        // WHY: The coordinator maps a chosen item back to the choice at the same index, so the items
        // must be exactly the choices, in order. `NSPopUpButton.addItems(withTitles:)` silently drops
        // an earlier item with a repeated title, which would shift every later index and write a
        // different value than the one the user picked. An empty value is the one a cleared field
        // leaves, and it must stay an item rather than vanish or become a separator.
        let selection = RecordedSelection("")
        let picker = HostedPicker(choices: ["", "tts-1", "tts-1-hd", "tts-1"], selection: selection, testCase: self)

        XCTAssertEqual(picker.button?.itemTitles, ["", "tts-1", "tts-1-hd", "tts-1"])
        XCTAssertEqual(picker.button?.itemArray.map(\.isSeparatorItem), [false, false, false, false])
        XCTAssertEqual(picker.button?.indexOfSelectedItem, 0)

        picker.choose(itemAt: 3)
        XCTAssertEqual(selection.writes, ["tts-1"], "The chosen item's own choice must be written once.")
    }

    func testChoosingAnItemWritesThatChoiceOnce() {
        // WHY: A choice is how a suggestion reaches the setting, so it must write exactly the chosen
        // value and write it once: never would leave the choice unapplied, and twice would repeat
        // the row's edit callback, which a Settings row counts on running once per edit.
        let selection = RecordedSelection("alloy")
        let picker = HostedPicker(choices: ["alloy", "nova", "sage"], selection: selection, testCase: self)

        picker.choose(itemAt: 2)

        XCTAssertEqual(selection.writes, ["sage"])
        XCTAssertEqual(picker.button?.titleOfSelectedItem, "sage")
    }

    func testAChoiceWritesTheBindingTheLatestRenderSupplied() {
        // WHY: SwiftUI hands the picker a fresh binding on each render, and the one it was created
        // with may address storage the row no longer shows. A choice must reach the current one.
        let original = RecordedSelection("alloy")
        let current = RecordedSelection("alloy")
        let picker = HostedPicker(choices: ["alloy", "nova"], selection: original, testCase: self)

        picker.render(choices: ["alloy", "nova"], selection: current)
        picker.choose(itemAt: 1)

        XCTAssertEqual(current.writes, ["nova"])
        XCTAssertEqual(original.writes, [])
    }

    func testANewBoundValueMovesTheSelectionWithoutWritingOrRebuildingTheItems() {
        // WHY: Typing in the field beside the picker changes the bound value, and the picker must
        // then show that value. Echoing it back to the binding would run the row's edit callback a
        // second time for one keystroke, and rebuilding unchanged items would replace the menu a
        // user may be reading for no change in what it offers.
        let selection = RecordedSelection("alloy")
        let picker = HostedPicker(choices: ["alloy", "nova"], selection: selection, testCase: self)
        let itemsBefore = picker.button?.itemArray ?? []

        selection.value = "nova"
        picker.render(choices: ["alloy", "nova"])

        XCTAssertEqual(picker.button?.titleOfSelectedItem, "nova")
        XCTAssertEqual(selection.writes, [], "An update must never write the binding.")
        let itemsAfter = picker.button?.itemArray ?? []
        XCTAssertEqual(itemsAfter.count, itemsBefore.count)
        XCTAssertTrue(zip(itemsBefore, itemsAfter).allSatisfy { $0 === $1 }, "Unchanged choices must keep their items.")
    }

    func testNewChoicesReplaceTheItemsWithoutWritingTheBinding() {
        // WHY: A switched provider or an off-catalog value changes what the picker offers. The items
        // must follow, or choosing one would write a value from the old list, and following them must
        // not write the binding either.
        let selection = RecordedSelection("tts-1")
        let picker = HostedPicker(choices: ["tts-1", "tts-1-hd"], selection: selection, testCase: self)

        picker.render(choices: ["typed-model", "tts-1", "tts-1-hd"])

        XCTAssertEqual(picker.button?.itemTitles, ["typed-model", "tts-1", "tts-1-hd"])
        XCTAssertEqual(picker.button?.titleOfSelectedItem, "tts-1")
        XCTAssertEqual(selection.writes, [])

        picker.choose(itemAt: 0)
        XCTAssertEqual(selection.writes, ["typed-model"], "A choice must come from the current items.")
    }

    func testABoundValueMissingFromTheChoicesShowsNoItemAndWritesNothing() {
        // WHY: Settings always offers the bound value among the choices, but the picker on its own
        // must not invent a selection when it is absent: showing another item, or writing one to the
        // binding, would display or save a value nobody chose.
        let selection = RecordedSelection("unlisted")
        let picker = HostedPicker(choices: ["alloy", "nova"], selection: selection, testCase: self)

        XCTAssertEqual(picker.button?.indexOfSelectedItem, -1)
        XCTAssertNil(picker.button?.titleOfSelectedItem)
        XCTAssertEqual(selection.writes, [])
    }

    func testPickerStatesTheNameItIsGiven() {
        // WHY: The row draws the button 30 points wide, showing only its arrows, so its name is the
        // only thing that tells VoiceOver what it offers. A new render's name must replace the old.
        let picker = HostedPicker(choices: ["tts-1"], selection: RecordedSelection("tts-1"), testCase: self)
        XCTAssertEqual(picker.button?.accessibilityLabel(), "Test suggestions")

        picker.render(choices: ["tts-1"], label: "Renamed suggestions")

        XCTAssertEqual(picker.button?.accessibilityLabel(), "Renamed suggestions")
    }

    func testPickerKeepsItsRowsThirtyPointSlotBesideTheField() {
        // WHY: A pop-up button left to size itself takes the width of its longest title, and in the
        // row's 30-point slot it then spreads across the text field it sits beside. The row has
        // always shown the picker as its arrows alone in that slot.
        var host: NSHostingView? = NSHostingView(rootView: Form {
            ModelVoiceConfigurationView(
                ttsModel: .constant("gpt-realtime-2.1-mini"),
                ttsVoice: .constant("alloy"),
                provider: .openAI,
                onModelChange: {},
                onVoiceChange: {}
            )
        })
        host?.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        settleHostedView(host, file: #filePath, line: #line)

        let buttons = host?.descendants(of: NSPopUpButton.self) ?? []
        var fields: [NSTextField] = []
        host?.collectEditableTextFields(into: &fields)
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(fields.count, 2)
        for (button, field) in zip(buttons, fields) {
            let buttonFrame = button.convert(button.bounds, to: host)
            let fieldFrame = field.convert(field.bounds, to: host)
            XCTAssertEqual(buttonFrame.width, 30, "The picker must take its slot's width.")
            XCTAssertGreaterThanOrEqual(buttonFrame.minX, fieldFrame.maxX, "The picker must not cover its field.")
        }

        host = nil
        drainHostedMainQueue(file: #filePath, line: #line)
    }

    func testPickerOfferedNoWidthKeepsTheWidthItsTitlesNeed() {
        // WHY: SwiftUI asks for a view's ideal size by offering no width. The picker must then report
        // its natural width rather than none, or a layout measuring it would collapse it.
        let host = NSHostingView(
            rootView: SuggestionPicker(
                choices: ["tts-1", "tts-1-hd"],
                accessibilityLabel: "Test suggestions",
                selection: .constant("tts-1")
            )
            .fixedSize()
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()

        guard let button = host.descendants(of: NSPopUpButton.self).first else {
            return XCTFail("The picker must render a pop-up button.")
        }
        XCTAssertEqual(button.frame.width, button.intrinsicContentSize.width)
        XCTAssertGreaterThan(button.frame.width, 30)
    }
}

/// A bound value a test owns, recording every write the picker makes to it.
@MainActor
final class RecordedSelection {
    var value: String
    private(set) var writes: [String] = []

    init(_ value: String) {
        self.value = value
    }

    var binding: Binding<String> {
        Binding(get: { self.value }, set: { self.value = $0; self.writes.append($0) })
    }
}

/// Hosts one `SuggestionPicker` over a `RecordedSelection` and re-renders it on request.
@MainActor
private final class HostedPicker {
    private var selection: RecordedSelection
    private var host: NSHostingView<SuggestionPicker>?

    var button: NSPopUpButton? {
        host?.descendants(of: NSPopUpButton.self).first
    }

    init(choices: [String], selection: RecordedSelection, testCase: XCTestCase) {
        self.selection = selection
        let host = NSHostingView(
            rootView: SuggestionPicker(choices: choices, accessibilityLabel: "Test suggestions", selection: selection.binding)
        )
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        self.host = host
        testCase.addTeardownBlock {
            self.host = nil
            drainHostedMainQueue(file: #filePath, line: #line)
        }
        settleHostedView(host, file: #filePath, line: #line)
    }

    /// Renders the picker again, as SwiftUI does when its inputs change, over the same selection
    /// unless another is given.
    func render(choices: [String], selection newSelection: RecordedSelection? = nil, label: String = "Test suggestions") {
        if let newSelection { selection = newSelection }
        host?.rootView = SuggestionPicker(choices: choices, accessibilityLabel: label, selection: selection.binding)
        settleHostedView(host, file: #filePath, line: #line)
    }

    /// Chooses the item at `index` the way a click on it does.
    func choose(itemAt index: Int) {
        guard let menu = button?.menu, menu.items.indices.contains(index) else {
            return XCTFail("The picker offers no item at \(index).")
        }
        menu.performActionForItem(at: index)
        settleHostedView(host, file: #filePath, line: #line)
    }
}

@MainActor
extension NSView {
    /// Every descendant of `type`, this view included, in rendering order.
    func descendants<ViewType: NSView>(of type: ViewType.Type) -> [ViewType] {
        ((self as? ViewType).map { [$0] } ?? []) + subviews.flatMap { $0.descendants(of: type) }
    }
}
