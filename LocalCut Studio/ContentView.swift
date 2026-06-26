import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalCutCore

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
            ViewCommands(model: model)
        }
    }
}

/// Inserts "Show Diagnostics" into the standard View menu instead of a new
/// menu, so it sits next to system items like Show/Hide Sidebar rather than
/// creating a duplicate "View" entry.
struct ViewCommands: Commands {
    @Bindable var model: EditorModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle(isOn: $model.isDiagnosticsVisible) {
                Text("Show Diagnostics")
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
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
            Menu("Open Recent") {
                let urls = recentProjectURLs
                if urls.isEmpty {
                    Text("No Recent Documents")
                } else {
                    ForEach(urls, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            model.requestOpenRecent(url)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        NSDocumentController.shared.clearRecentDocuments(nil)
                    }
                }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.requestSave() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { model.requestSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Convert to Bundle…") { model.requestConvertToBundle() }
                .disabled(!model.canConvertToBundle)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitle) { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            Button(model.redoTitle) { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
        // Edit-menu entries mirror the toolbar buttons so keyboard-driven
        // workflows + the menu bar both reach the same actions. A top-level
        // "Timeline" menu would be non-standard for a macOS app — grouping
        // inside Edit (after pasteboard) keeps the menu bar conventional.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Split Clip at Playhead") { model.splitSelectedClipAtPlayhead() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.selectedClipID == nil)
            Button("Analyse Beats for Selection") { model.analyzeBeatsForSelection() }
                .disabled(!model.canAnalyzeBeatsForSelection)
            Button("Cut Selected Clip at Beats") { model.cutSelectedClipAtBeats() }
                .disabled(!model.canCutSelectedClipAtBeats)
            Button("Align Selected Clip to Beat") { model.alignSelectedClipToBeat() }
                .disabled(!model.canAlignSelectedClipToBeat)
            Button("Add Transition at Selected Cut") { model.addTransitionToSelectedClip() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!model.canAddTransitionAtSelection)
            Button("Remove Transition") { model.removeSelectedTransition() }
                .disabled(model.selectedTransitionClipID == nil)
            Divider()
            Button("Previous Marker") { model.selectPreviousMarker() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.project.markers.isEmpty)
            Button("Next Marker") { model.selectNextMarker() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.project.markers.isEmpty)
        }
    }

    private var recentProjectURLs: [URL] {
        NSDocumentController.shared.recentDocumentURLs.filter { url in
            url.pathExtension == ProjectDocument.fileExtension
                || url.pathExtension == ProjectBundleLayout.fileExtension
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
        .safeAreaInset(edge: .bottom) { statusBar }
        .onDisappear { model.teardownAudioMetering() }
        .background(WindowConfigurator(model: model))
        .overlay(alignment: .topTrailing) {
            if model.isDiagnosticsVisible {
                DiagnosticsView(agent: model.diagnostics)
                    // Clear the unified toolbar (~52 pt on the .unified style)
                    // plus a few points of breathing room so the panel doesn't
                    // butt against the window chrome.
                    .padding(.top, 60)
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
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

            if model.renderQueue.isRunning {
                ProgressView(value: model.renderQueue.totalProgress)
                    .frame(width: 120)
                    .accessibilityLabel("Render queue progress")
            }

            Button {
                exportTapped()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.totalDuration <= 0)
            .help("Queue an export with the default preset.")
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack {
            if !model.unresolvedMedia.isEmpty {
                relinkBanner
                Spacer()
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .allowsHitTesting(false)
                .accessibilityLabel(model.statusMessage)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        // Announce status changes so background work and errors reach VoiceOver
        // (A11Y-CHECKLIST: status line is an announced live region).
        .onChange(of: model.statusMessage) { _, message in
            AccessibilityNotification.Announcement(message).post()
        }
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
    }

    private func exportTapped() {
        // Match the default preset's container so the panel filter, suggested
        // filename, and the actual encode line up.
        let preset = BuiltInExportPresets.defaultPreset
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: preset.defaultFilenameExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(model.project.name).\(preset.defaultFilenameExtension)"
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
            guard model.confirmClose(window: sender) else { return false }
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
