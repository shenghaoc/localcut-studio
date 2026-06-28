import AppKit
import SwiftUI

/// A non-activating, always-on-top panel for recording controls.
/// The panel floats above all apps and is excluded from screen capture.
final class RecorderFloatingPanel: NSPanel {
    /// The CGWindowID of this panel, used to exclude it from screen capture.
    private(set) var panelWindowID: CGWindowID = 0

    init(model: EditorModel) {
        // Initial content rect — will be repositioned on screen.
        let rect = NSRect(x: 0, y: 0, width: 280, height: 120)
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)

        // Non-activating: clicking the panel doesn't steal focus from the app
        // being recorded.
        isFloatingPanel = true
        level = .statusBar + 1
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        // Allow the panel to appear in full-screen spaces.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // SwiftUI content.
        let hostingView = NSHostingView(rootView: RecorderFloatingPanelContent(model: model))
        hostingView.frame = rect
        contentView = hostingView

        // Position in the bottom-right corner of the main screen.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelWidth: CGFloat = 280
            let panelHeight: CGFloat = 120
            let x = screenFrame.maxX - panelWidth - 20
            let y = screenFrame.minY + 20
            setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Break the retain cycle: EditorModel -> floatingPanelController -> panel
    /// -> contentView -> rootView -> EditorModel.
    override func close() {
        contentView = nil
        super.close()
    }

    /// Capture the window ID after the panel is shown on screen.
    func captureWindowID() {
        panelWindowID = CGWindowID(windowNumber)
    }
}

/// Manages the floating panel lifecycle from the EditorModel.
@MainActor
final class FloatingPanelController {
    private var panel: RecorderFloatingPanel?

    func show(model: EditorModel) {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let p = RecorderFloatingPanel(model: model)
        p.captureWindowID()
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.close()
        panel = nil
    }

    /// The CGWindowID of the panel, or 0 if not shown.
    var windowID: CGWindowID {
        panel?.panelWindowID ?? 0
    }

    var isShown: Bool {
        panel?.isVisible ?? false
    }
}
