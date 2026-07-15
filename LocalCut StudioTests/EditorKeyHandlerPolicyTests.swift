import AppKit
import SwiftUI
import Testing
@testable import LocalCut_Studio

// The focused timeline uses SwiftUI `onKeyPress`, rather than a window-wide
// NSEvent monitor. These tests preserve the pure key/modifier policy while UI
// verification covers SwiftUI's first-responder routing for text fields and
// other controls.

private func decide(
    _ key: TimelineShortcutPolicy.Key,
    modifiers: EventModifiers = []
) -> TimelineShortcutPolicy.Action {
    TimelineShortcutPolicy.action(key: key, modifiers: modifiers)
}

@Suite("TimelineShortcutPolicy")
struct TimelineShortcutPolicyTests {
    @Test("Plain Space with timeline focus toggles play")
    func plainSpaceTogglesPlay() {
        #expect(decide(.space) == .togglePlay)
    }

    @Test("Shift+Space is ignored")
    func shiftSpaceIgnored() {
        #expect(decide(.space, modifiers: .shift) == .ignore)
    }

    @Test("Command+Space is ignored")
    func commandSpaceIgnored() {
        #expect(decide(.space, modifiers: .command) == .ignore)
    }

    @Test("M adds a marker")
    func markerAddsMarker() {
        #expect(decide(.marker) == .addMarker)
    }

    @Test("Shift+M renames the selected marker")
    func shiftMarkerRenames() {
        #expect(decide(.marker, modifiers: .shift) == .renameMarker)
    }

    @Test("Caps Lock remains a passive hardware-state modifier")
    func capsLockMarkerAddsMarker() {
        #expect(decide(.marker, modifiers: .capsLock) == .addMarker)
    }

    @Test("Numeric keypad remains a passive hardware-state modifier")
    func numericPadDeleteMaybeDeletes() {
        #expect(decide(.deleteForward, modifiers: .numericPad) == .maybeDeleteMarker)
    }

    @Test("Function key remains a passive hardware-state modifier")
    func functionDeleteMaybeDeletes() {
        let function = EventModifiers(rawValue: Int(NSEvent.ModifierFlags.function.rawValue))
        #expect(decide(.deleteBackward, modifiers: function) == .maybeDeleteMarker)
    }

    @Test("Command+M is ignored")
    func commandMarkerIgnored() {
        #expect(decide(.marker, modifiers: .command) == .ignore)
    }

    @Test("Control+M is ignored")
    func controlMarkerIgnored() {
        #expect(decide(.marker, modifiers: .control) == .ignore)
    }

    @Test("Option+M is ignored")
    func optionMarkerIgnored() {
        #expect(decide(.marker, modifiers: .option) == .ignore)
    }

    @Test("Backspace asks the marker handler whether a marker is selected")
    func backspaceMaybeDeletes() {
        #expect(decide(.deleteBackward) == .maybeDeleteMarker)
    }

    @Test("Forward Delete also routes to the marker handler")
    func forwardDeleteMaybeDeletes() {
        #expect(decide(.deleteForward) == .maybeDeleteMarker)
    }

    @Test("Option Delete is ignored so native word-delete can win")
    func optionDeleteIgnored() {
        #expect(decide(.deleteBackward, modifiers: .option) == .ignore)
    }

    @Test("Control Delete is ignored")
    func controlDeleteIgnored() {
        #expect(decide(.deleteForward, modifiers: .control) == .ignore)
    }

    @Test("Shift Delete remains a timeline deletion candidate")
    func shiftDeleteMaybeDeletes() {
        #expect(decide(.deleteBackward, modifiers: .shift) == .maybeDeleteMarker)
    }

    @Test("Any other keystroke is ignored")
    func otherKeysIgnored() {
        #expect(decide(.other) == .ignore)
    }
}
