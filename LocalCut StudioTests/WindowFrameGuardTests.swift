import AppKit
import CoreGraphics
import Testing
@testable import LocalCut_Studio

// New-window placement is now a pure SwiftUI scene policy. Restored windows
// are left to macOS; these tests lock the size calculation for fresh windows
// without reintroducing AppKit frame mutation.

@Suite("EditorWindowPlacement")
struct EditorWindowPlacementTests {
    @Test("Uses the preferred editor size on a roomy display")
    func usesPreferredSize() {
        let size = EditorWindowPlacement.fittedSize(
            idealSize: .zero,
            visibleRect: CGRect(x: 0, y: 0, width: 2200, height: 1400))
        #expect(size == EditorWindowPlacement.preferredSize)
    }

    @Test("Honours a larger ideal size when it fits")
    func honoursLargerIdealSize() {
        let size = EditorWindowPlacement.fittedSize(
            idealSize: CGSize(width: 1500, height: 920),
            visibleRect: CGRect(x: 0, y: 0, width: 2000, height: 1200))
        #expect(size == CGSize(width: 1500, height: 920))
    }

    @Test("Clamps a fresh window inside the visible display inset")
    func clampsToVisibleDisplay() {
        let size = EditorWindowPlacement.fittedSize(
            idealSize: CGSize(width: 1800, height: 1200),
            visibleRect: CGRect(x: 0, y: 0, width: 1000, height: 700))
        #expect(size == CGSize(width: 920, height: 620))
    }

    @Test("Never produces a non-positive size on a tiny display")
    func guardsTinyDisplays() {
        let size = EditorWindowPlacement.fittedSize(
            idealSize: .zero,
            visibleRect: CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(size == CGSize(width: 1, height: 1))
    }
}

@Suite("Window close bridge")
struct WindowCloseBridgeTests {
    @MainActor
    private final class VetoingPreviousDelegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    }

    @MainActor
    @Test("A clean close is not vetoed by SwiftUI's previous delegate")
    func cleanCloseDoesNotForwardToPreviousDelegate() {
        let model = EditorModel()
        let coordinator = WindowConfigurator.Coordinator(model: model, onWindowActivated: {})
        let previousDelegate = VetoingPreviousDelegate()
        coordinator.previousDelegate = previousDelegate

        #expect(coordinator.windowShouldClose(NSWindow()) == true)
    }
}
