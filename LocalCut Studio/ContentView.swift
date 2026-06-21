import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct LocalCutStudioApp: App {
    // The editor owns the single AVPlayer and is the document controller; it lives
    // at app scope so the menu commands and window can share it.
    @State private var model = EditorModel()

    var body: some Scene {
        WindowGroup {
            EditorView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            DocumentCommands(model: model)
        }
    }
}

/// File and Edit menu items backed by the editor's custom document controller.
struct DocumentCommands: Commands {
    let model: EditorModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { model.requestNew() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { model.requestOpen() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.requestSave() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { model.requestSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitle) { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            Button(model.redoTitle) { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
    }
}

/// Top-level editor layout: media bin · preview · inspector across the top, with
/// the timeline spanning the bottom. This is the native shell that mirrors the
/// browser editor's three-pane workspace.
struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VSplitView {
            HSplitView {
                MediaBinView(model: model)
                    .frame(minWidth: 200, idealWidth: 240)

                PreviewView(model: model)
                    .frame(minWidth: 380)
                    .layoutPriority(1)

                InspectorView(model: model)
                    .frame(minWidth: 240, idealWidth: 280)
            }
            .frame(minHeight: 320)

            TimelineView(model: model)
                .frame(minHeight: 200, idealHeight: 260)
        }
        .toolbar { toolbarContent }
        .navigationTitle(model.project.name)
        .overlay(alignment: .bottom) { statusBar }
        .background(WindowConfigurator(model: model))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.splitSelectedClipAtPlayhead()
            } label: {
                Label("Split", systemImage: "scissors")
            }
            .disabled(model.selectedClipID == nil)
            .help("Split clip at playhead")

            Button {
                model.addTransitionToSelectedClip()
            } label: {
                Label("Transition", systemImage: "square.filled.and.line.vertical.and.square.filled")
            }
            .disabled(!model.canAddTransitionAtSelection)
            .help("Add a transition at the selected clip's cut")

            Button(role: .destructive) {
                if model.selectedTransitionClipID != nil {
                    model.removeSelectedTransition()
                } else {
                    model.deleteSelectedClip()
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selectedClipID == nil && model.selectedTransitionClipID == nil)
            .keyboardShortcut(.delete, modifiers: [])
            .help("Delete selected clip or transition")

            Spacer()

            if model.isExporting, let progress = model.exportProgress {
                ProgressView(value: progress)
                    .frame(width: 120)
            }

            Button {
                exportTapped()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.isExporting || model.totalDuration <= 0)
            .help("Export movie…")
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 6) {
            if !model.unresolvedMedia.isEmpty {
                relinkBanner
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .allowsHitTesting(false)
        }
        .padding(.bottom, 6)
    }

    private var relinkBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("\(model.unresolvedMedia.count) media file(s) need relinking.")
                .font(.caption)
            Button("Relink…") { Task { await model.relinkNextMissingMedia() } }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func exportTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(model.project.name).mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(to: url) }
    }
}

/// Bridges the SwiftUI window to AppKit so the title-bar edited dot, the
/// represented document URL, and the save-on-close prompt reflect the model.
/// The previous (SwiftUI) window delegate is preserved and forwarded to.
private struct WindowConfigurator: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingView()
        let coordinator = context.coordinator
        // viewDidMoveToWindow fires exactly when the view joins the window
        // hierarchy — no polling or DispatchQueue races.
        view.onWindowChanged = { [weak coordinator] window in coordinator?.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.attach(to: nsView.window)
    }

    /// An `NSView` that reports when it is attached to (or removed from) a window.
    private final class WindowTrackingView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var model: EditorModel
        weak var window: NSWindow?
        nonisolated(unsafe) weak var previousDelegate: NSWindowDelegate?

        init(model: EditorModel) {
            self.model = model
        }

        func attach(to window: NSWindow?) {
            guard let window else {
                // Detached: hand the delegate back to SwiftUI so its window
                // lifecycle keeps working after this view goes away.
                if let current = self.window, current.delegate === self {
                    current.delegate = previousDelegate
                }
                self.window = nil
                previousDelegate = nil
                return
            }
            if window !== self.window {
                self.window = window
                if window.delegate !== self {
                    previousDelegate = window.delegate
                    window.delegate = self
                }
            }
            sync()
        }

        /// Mirrors the model's edited/URL state onto the window chrome.
        func sync() {
            window?.isDocumentEdited = model.isDirty
            window?.representedURL = model.documentURL
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.confirmCloseSynchronously() else { return false }
            // Respect SwiftUI's own close decision if it has one.
            if let previousDelegate, previousDelegate.responds(to: #selector(windowShouldClose(_:))) {
                return previousDelegate.windowShouldClose?(sender) ?? true
            }
            return true
        }

        // Forward any delegate calls we don't implement to SwiftUI's delegate.
        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (previousDelegate?.responds(to: aSelector) ?? false)
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if previousDelegate?.responds(to: aSelector) == true { return previousDelegate }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
