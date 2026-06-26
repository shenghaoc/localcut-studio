import Testing
import AppKit
@testable import LocalCut_Studio

// The window-scoped key handler used to be one private function on a
// Coordinator with zero coverage — the same accessibility/keyboard-trap class
// of regression (Codex P1 on d8c7ee2) could silently come back. These tests
// drive the pure decision layer with the same booleans the live handler
// derives from first-responder state, locking the carve-outs in place.

private let kSpace: UInt16 = 0x31
private let kBackspace: UInt16 = 0x33
private let kForwardDelete: UInt16 = 0x75
private let kReturn: UInt16 = 0x24

private func decide(
    _ keyCode: UInt16,
    chars: String = "",
    modifiers: NSEvent.ModifierFlags = [],
    textInput: Bool = false,
    nonTimelineFocus: Bool = false
) -> EditorKeyHandlerPolicy.Action {
    EditorKeyHandlerPolicy.action(
        keyCode: keyCode,
        chars: chars,
        modifiers: modifiers,
        firstResponderIsTextInput: textInput,
        firstResponderIsNonTimelineFocus: nonTimelineFocus)
}

@Suite("EditorKeyHandlerPolicy")
struct EditorKeyHandlerPolicyTests {

    // MARK: - Space

    @Test("Plain Space with timeline focused toggles play")
    func plainSpaceTogglesPlay() {
        #expect(decide(kSpace) == .togglePlay)
    }

    @Test("Space yields to a focused text input (typing a space)")
    func spaceYieldsToTextInput() {
        #expect(decide(kSpace, textInput: true) == .ignore)
    }

    @Test("Space yields to a focused non-text control (NSControl / SwiftUI host)")
    func spaceYieldsToFocusedNonTextControl() {
        // The Codex P1 trap fix: Tab-focused checkbox/button receives Space.
        #expect(decide(kSpace, nonTimelineFocus: true) == .ignore)
    }

    @Test("Shift+Space is ignored (not a marker shortcut)")
    func shiftSpaceIgnored() {
        #expect(decide(kSpace, modifiers: .shift) == .ignore)
    }

    @Test("Cmd+Space is ignored (belongs to a different command)")
    func cmdSpaceIgnored() {
        #expect(decide(kSpace, modifiers: .command) == .ignore)
    }

    // MARK: - M / Shift+M

    @Test("M adds a marker when timeline has focus")
    func mAddsMarker() {
        #expect(decide(kReturn, chars: "m") == .addMarker)
    }

    @Test("Shift+M renames the selected marker")
    func shiftMRenames() {
        #expect(decide(kReturn, chars: "M", modifiers: .shift) == .renameMarker)
    }

    @Test("M with command modifier is ignored")
    func cmdMIgnored() {
        #expect(decide(kReturn, chars: "m", modifiers: .command) == .ignore)
    }

    @Test("M yields to a focused text input")
    func mYieldsToTextInput() {
        #expect(decide(kReturn, chars: "m", textInput: true) == .ignore)
    }

    @Test("M still fires when a non-text control owns focus — markers are an editor shortcut")
    func mStillFiresOverFocusedControl() {
        // M intentionally overrides any non-text focused control (which won't
        // do anything with M anyway); only Space yields to focused controls.
        #expect(decide(kReturn, chars: "m", nonTimelineFocus: true) == .addMarker)
    }

    // MARK: - Delete

    @Test("Backspace asks the marker handler whether a marker is selected")
    func backspaceMaybeDeletes() {
        #expect(decide(kBackspace) == .maybeDeleteMarker)
    }

    @Test("Forward-Delete also routes to the marker handler")
    func forwardDeleteMaybeDeletes() {
        #expect(decide(kForwardDelete) == .maybeDeleteMarker)
    }

    @Test("Delete yields to a focused text input (typing Backspace)")
    func deleteYieldsToTextInput() {
        #expect(decide(kBackspace, textInput: true) == .ignore)
    }

    @Test("Modifier-laden Delete is ignored (e.g. Option-Delete for word-delete)")
    func optionDeleteIgnored() {
        #expect(decide(kBackspace, modifiers: .option) == .ignore)
    }

    // MARK: - Unknown keys

    @Test("Any other plain keystroke is ignored")
    func otherKeysIgnored() {
        #expect(decide(0x00, chars: "a") == .ignore)
    }
}
