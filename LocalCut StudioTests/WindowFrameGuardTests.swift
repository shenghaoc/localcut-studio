import Testing
import CoreGraphics
@testable import LocalCut_Studio

// The first-launch frame guard's predicate (Codex P3 on d8c7ee2): if the
// window is still at SwiftUI's `.defaultSize`, AppKit hasn't restored a saved
// frame yet and we may centre the canvas; otherwise the restored layout wins.
// Lock the gate so a regression to "always override" doesn't silently clobber
// upgrading users' workspaces.

@Suite("WindowConfigurator.Coordinator: default-frame predicate")
struct WindowFrameGuardTests {
    private let defaultSize = CGSize(width: 1360, height: 860)

    @Test("Exact SwiftUI default size matches")
    func exactDefaultMatches() {
        #expect(WindowConfigurator.Coordinator.looksLikeSwiftUIDefaultSize(defaultSize, defaultSize: defaultSize))
    }

    @Test("Within 1 pt tolerance still matches (HiDPI rounding)")
    func subPixelTolerance() {
        let near = CGSize(width: defaultSize.width + 0.5, height: defaultSize.height - 0.7)
        #expect(WindowConfigurator.Coordinator.looksLikeSwiftUIDefaultSize(near, defaultSize: defaultSize))
    }

    @Test("Restored frame from previous session is NOT mistaken for default")
    func restoredFrameRejected() {
        let restored = CGSize(width: 1240, height: 760)
        #expect(!WindowConfigurator.Coordinator.looksLikeSwiftUIDefaultSize(restored, defaultSize: defaultSize))
    }

    @Test("Width matches but height differs ⇒ not default")
    func widthOnlyMatchNotDefault() {
        let partial = CGSize(width: defaultSize.width, height: 720)
        #expect(!WindowConfigurator.Coordinator.looksLikeSwiftUIDefaultSize(partial, defaultSize: defaultSize))
    }
}
