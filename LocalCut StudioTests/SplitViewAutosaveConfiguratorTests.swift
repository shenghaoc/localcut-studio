import Testing
import AppKit
@testable import LocalCut_Studio

// The autosave-on-collapse invariant is the central fix in commits 327c7b2,
// 4fae9de, d8c7ee2: when the inspector is collapsed, the split-view divider
// position must NOT autosave (otherwise the 44pt collapsed width is written
// over the user's expanded layout). These tests pin the configurator's
// is-enabled gating behaviour deterministically without spinning up a window.

@MainActor
@Suite("SplitViewAutosaveConfigurator")
struct SplitViewAutosaveConfiguratorTests {

    private static func makeHostedSplitView(isVertical: Bool) -> (NSSplitView, SplitViewAutosaveConfigurator.ConfiguringView) {
        let split = NSSplitView()
        split.isVertical = isVertical
        // Two arranged subviews so NSSplitView behaves like a real one.
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        let inner = NSView()
        split.arrangedSubviews.first?.addSubview(inner)
        let configurator = SplitViewAutosaveConfigurator.ConfiguringView(
            autosaveName: "test.editor.workspace",
            isVertical: isVertical,
            isEnabled: true)
        inner.addSubview(configurator)
        return (split, configurator)
    }

    @Test("Sets identifier + autosaveName when enabled")
    func enabledArmsAutosave() {
        let (split, view) = Self.makeHostedSplitView(isVertical: true)

        view.configureSplitView()

        #expect(split.identifier?.rawValue == "test.editor.workspace")
        #expect(split.autosaveName == "test.editor.workspace")
    }

    @Test("Setting isEnabled=false clears autosaveName but keeps the identifier")
    func disabledClearsAutosaveOnly() {
        let (split, view) = Self.makeHostedSplitView(isVertical: true)
        view.configureSplitView()
        #expect(split.autosaveName == "test.editor.workspace")

        view.isEnabled = false
        view.configureSplitView()

        // autosaveName is the only signal AppKit reads to decide whether to
        // write the divider state — nil pauses autosaving without disturbing
        // the identifier (which would otherwise force a layout pass).
        #expect(split.autosaveName == nil)
        #expect(split.identifier?.rawValue == "test.editor.workspace")
    }

    @Test("Re-enabling restores autosaveName so subsequent drags persist again")
    func reEnableRestoresAutosave() {
        let (split, view) = Self.makeHostedSplitView(isVertical: true)
        view.configureSplitView()
        view.isEnabled = false
        view.configureSplitView()
        #expect(split.autosaveName == nil)

        view.isEnabled = true
        view.configureSplitView()
        #expect(split.autosaveName == "test.editor.workspace")
    }

    @Test("Only matches the split view whose vertical axis was requested")
    func walksToMatchingAxisOnly() {
        // Vertical configurator should NOT bind to a horizontal split view.
        let split = NSSplitView()
        split.isVertical = false                    // horizontal
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        let inner = NSView()
        split.arrangedSubviews.first?.addSubview(inner)
        let configurator = SplitViewAutosaveConfigurator.ConfiguringView(
            autosaveName: "should-not-bind",
            isVertical: true,                        // asks for vertical only
            isEnabled: true)
        inner.addSubview(configurator)

        configurator.configureSplitView()
        #expect(split.autosaveName == nil)
        #expect(split.identifier == nil)
    }
}
