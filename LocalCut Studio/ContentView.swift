import SwiftUI
import AppIntents
import AppKit
import UniformTypeIdentifiers
import LocalCutCore

/// Keeps cold-start App Intents and the visible window on the same editor model,
/// even if SwiftUI recreates the `App` value during the process lifetime.
@MainActor
private enum LocalCutStudioAppState {
    static let model = EditorModel()
    static let appIntentRouter = LocalCutAppIntentRouter(model: model)
}

@main
struct LocalCutStudioApp: App {
    // The editor owns the single AVPlayer and is the document controller; it lives
    // at app scope so the menu commands and window can share it.
    @State private var model = LocalCutStudioAppState.model

    @MainActor
    init() {
        let appIntentRouter = LocalCutStudioAppState.appIntentRouter
        AppDependencyManager.shared.add(dependency: appIntentRouter)
        // Activate memory pressure monitoring at app launch.
        MemoryPressureHandler.shared.activate()
    }

#if DEBUG
    private var runsRecorderUITestHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--localcut-ui-test-recorder-harness")
            || ProcessInfo.processInfo.environment["LOCALCUT_UI_TEST_RECORDER_HARNESS"] == "1"
    }
#endif

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if runsRecorderUITestHarness {
                RecorderUITestHarnessView()
                    .frame(minWidth: 420, minHeight: 320)
            } else {
                editorView
            }
#else
            editorView
#endif
        }
        .defaultSize(width: 1360, height: 860)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            DocumentCommands(model: model)
            ViewCommands(model: model)
            RecorderCommands(model: model)
        }
    }

    @MainActor
    private var editorView: some View {
        EditorView(model: model)
            .frame(minWidth: 1000, minHeight: 640)
    }
}

struct RecorderCommands: Commands {
    @Bindable var model: EditorModel

    var body: some Commands {
        CommandMenu("Record") {
            Button("Open Recorder") {
                model.requestRecorder()
            }
            .disabled(model.isRecording || model.isPaused || model.isCountdownActive || model.isStartingRecording || model.isPausingRecording || model.isStoppingRecording)

            Button("Choose Recordings Folder…") {
                _ = model.chooseRecordingsFolder()
            }
            .disabled(model.isRecording || model.isPaused || model.isCountdownActive || model.isStartingRecording || model.isPausingRecording || model.isStoppingRecording)

            Divider()

            Button("Collapse Recording Gaps") {
                model.collapseRecordingGap()
            }
            .disabled(!model.canCollapseRecordingGaps)

            Button("Retake Last Recording") {
                Task { await model.retakeRecording() }
            }
            .disabled(!model.canRetakeRecording)
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
            Toggle(isOn: $model.inspectorVisible) {
                Text("Show Inspector")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Toggle(isOn: $model.isDiagnosticsVisible) {
                Text("Show Diagnostics")
            }
            .keyboardShortcut("d", modifiers: [.command, .option])

            Divider()

            // Transport in the menu bar so playback has a discoverable home.
            // The Space shortcut for play/pause is handled by `EditorKeyHandler`
            // (a window-scoped NSEvent monitor in TimelineView.swift) — a bare
            // `.space` menu key-equivalent is global in AppKit and would swallow
            // spaces typed into text fields (e.g. the marker-rename popover).
            Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayPause() }
                .disabled(model.totalDuration <= 0)
            Button("Go to Start") { model.seek(toSeconds: 0) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.totalDuration <= 0)
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
            Divider()
            Button("Import…") { model.requestImport() }
                .keyboardShortcut("i", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.requestSave() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { model.requestSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Convert to Bundle…") { model.requestConvertToBundle() }
                .disabled(!model.canConvertToBundle)
            Divider()
            // Mirror the toolbar's primary output action so Export has a menu home
            // and a standard shortcut.
            Button("Export…") { model.requestExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.totalDuration <= 0)
            Divider()
            Button("Export Timeline (.otio)…") { model.requestExportOtio() }
                .disabled(model.totalDuration <= 0)
            Button("Export EDL (.edl)…") { model.requestExportEdl() }
                .disabled(model.totalDuration <= 0)
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
            // Mirror the destructive toolbar button so deleting a clip/transition
            // has a menu home; the toolbar keeps the same ⌫ shortcut.
            Button("Delete Selected Clip") {
                if model.selectedTransitionClipID != nil {
                    model.removeSelectedTransition()
                } else {
                    model.deleteSelectedClip()
                }
            }
            .disabled(model.selectedClipID == nil && model.selectedTransitionClipID == nil)
            Divider()
            // No key equivalent here: the timeline's EditorKeyHandler already owns
            // the bare "m" key and correctly yields it to focused text fields. A
            // bare-letter menu shortcut would instead hijack "m" while the user is
            // typing (rename popover, captions). The menu item stays for discovery.
            Button("Add Marker") { model.addMarkerAtPlayhead() }
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

                if model.inspectorVisible {
                    EditorSideRailView(model: model) {
                        model.inspectorVisible = false
                    }
                    .frame(minWidth: 300, idealWidth: 340)
                } else {
                    CollapsedSideRailView {
                        model.inspectorVisible = true
                    }
                    .frame(width: 44)
                }
            }
            .frame(minHeight: 320)
            .background(SplitViewAutosaveConfigurator(autosaveName: "editor.workspace.columns",
                                                       isVertical: true,
                                                       isEnabled: model.inspectorVisible))

            TimelineView(model: model)
                .frame(minHeight: 200, idealHeight: 260)
        }
        .background(SplitViewAutosaveConfigurator(autosaveName: "editor.workspace.rows",
                                                   isVertical: false))
        .toolbar { toolbarContent }
        .navigationTitle(model.project.name)
        .tint(.lcAccent)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { statusBar }
        .onAppear { Task { await model.scanRecoveredRecordings() } }
        .onDisappear { model.teardownAudioMetering() }
        .sheet(isPresented: $model.isRecorderPresented) {
            RecorderSetupView(model: model)
        }
        .overlay {
            if model.isCountdownActive {
                RecordingCountdownView(model: model)
                    .transition(.opacity)
            }
        }
        .background(WindowConfigurator(model: model))
        .overlay(alignment: .topTrailing) {
            if model.isDiagnosticsVisible {
                DiagnosticsView(agent: model.diagnostics)
                    // Overlay content already renders inside the unified toolbar's
                    // reserved safe area, so a small fixed inset keeps the panel
                    // off the chrome without hard-coding the toolbar's pixel height.
                    .padding(.top, 8)
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
                Label("Add Transition", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .disabled(!model.canAddTransitionAtSelection)
            .help("Add transition at selected cut")
            .accessibilityLabel("Add transition at selected cut")

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

            if model.isRecording || model.isPaused {
                if model.isPaused {
                    Button {
                        Task { await model.resumeRecording() }
                    } label: {
                        Label("Resume", systemImage: "play.circle.fill")
                    }
                    .help("Resume recording")
                } else {
                    Button {
                        Task { await model.pauseRecording() }
                    } label: {
                        Label("Pause", systemImage: "pause.circle.fill")
                    }
                    .help("Pause recording")
                }
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .disabled(model.isStartingRecording || model.isPausingRecording || model.isStoppingRecording)
                .help("Stop recording")
            } else {
                Button {
                    model.requestRecorder()
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .disabled(model.isCountdownActive || model.isStartingRecording || model.isPausingRecording || model.isStoppingRecording)
                .help("Open recorder")

                if model.hasLastRecordingTake {
                    Button {
                        model.collapseRecordingGap()
                    } label: {
                        Label("Collapse Recording Gaps", systemImage: "arrow.left.and.right")
                    }
                    .disabled(!model.canCollapseRecordingGaps)
                    .help("Collapse pause gaps in the last recording")

                    Button {
                        Task { await model.retakeRecording() }
                    } label: {
                        Label("Retake Last Recording", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!model.canRetakeRecording)
                    .help("Retake the last recording in the same timeline slot")
                }
            }

            Button {
                model.inspectorVisible.toggle()
            } label: {
                Label(model.inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .help(model.inspectorVisible ? "Hide inspector panel" : "Show inspector panel")
            .accessibilityLabel(model.inspectorVisible ? "Hide inspector panel" : "Show inspector panel")

            Spacer()

            if model.renderQueue.isRunning {
                ProgressView(value: model.renderQueue.totalProgress)
                    .frame(width: 120)
                    .accessibilityLabel("Render queue progress")
            }

            Button {
                model.requestExport()
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
            if model.isRecording || model.isPaused {
                Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(model.isPaused ? .orange : .red)
                    .font(.caption)
                    .accessibilityHidden(true)
                RecordingElapsedView(model: model)
                Text("\(model.recordingSourceCount) source\(model.recordingSourceCount == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if model.recordingBackpressureCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("\(model.recordingBackpressureCount) backpressure warning\(model.recordingBackpressureCount == 1 ? "" : "s")")
                }
                if let recordingStatusMessage {
                    Text(recordingStatusMessage)
                        .font(.caption)
                        .foregroundStyle(recordingStatusColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .accessibilityLabel(recordingStatusMessage)
                }
                RecordingDiskSpaceView(model: model)
                Spacer()
            } else {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .onChange(of: model.statusMessage) { _, message in
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private var recordingStatusMessage: String? {
        if model.recordingDiskWarning == .stop {
            return "Disk space critically low — stopping recording."
        }
        if model.recordingDiskWarning == .warn {
            return "Low disk space — recording will stop at 5% free."
        }
        if model.recordingBackpressureCount > 0 || model.statusMessage != "Recording…" {
            return model.statusMessage
        }
        return nil
    }

    private var recordingStatusColor: Color {
        if model.recordingDiskWarning != nil || model.recordingBackpressureCount > 0 {
            return .yellow
        }
        return .secondary
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
}

private struct CollapsedSideRailView: View {
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button {
                onExpand()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show inspector panel")
            .accessibilityLabel("Show inspector panel")

            Text("Inspector")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: 30, height: 88)
                .accessibilityHidden(true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}

/// Bridges the SwiftUI window to AppKit so the title-bar edited dot, the
/// represented document URL, and the save-on-close prompt reflect the model.
/// The previous (SwiftUI) window delegate is preserved and forwarded to.
/// Bridges the SwiftUI editor view to its hosting `NSWindow` so the title-bar
/// edited dot, the represented document URL, and the save-on-close prompt all
/// reflect the model. `internal` (not `private`) so tests can reach the
/// `Coordinator.looksLikeSwiftUIDefaultSize` predicate that gates the first-
/// launch frame override.
struct WindowConfigurator: NSViewRepresentable {
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
        /// Previous window delegate, restored on detach.
        ///
        /// **Isolation invariant:** Set/read on `@MainActor` in `attach(to:)`;
        /// also read from nonisolated `responds(to:)` and
        /// `forwardingTarget(for:)` for delegate message forwarding.
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
                // Symmetric teardown for the prior window (future-proofs the
                // moment a second editor scene or window rebuild lands — today
                // teardown happens through viewDidMoveToWindow(nil), but this
                // closes the asymmetry cheaply; audit P3).
                if let previous = self.window, previous !== window,
                   previous.delegate === self {
                    previous.delegate = previousDelegate
                }
                self.window = window
                if window.delegate !== self {
                    previousDelegate = window.delegate
                    window.delegate = self
                }
                Self.applyInitialFrameIfNeeded(window)
            }
            sync()
        }

        /// Size the editor to a comfortable canvas the first time it ever opens,
        /// centred on the active screen. Guarded by a one-shot default so later
        /// launches keep whatever size the user left it at.
        private static var didEnqueueInitialFrame = false

        private static func applyInitialFrameIfNeeded(_ window: NSWindow) {
            let key = "editor.didSetInitialWindowFrame"
            // `attach(to:)` can fire several times within one run-loop tick during
            // window setup; the in-memory flag stops us enqueuing the deferred
            // block more than once before the UserDefaults one-shot is written.
            guard !didEnqueueInitialFrame, !UserDefaults.standard.bool(forKey: key) else { return }
            didEnqueueInitialFrame = true
            // Defer past SwiftUI's own first-layout sizing pass, which otherwise
            // clobbers a frame set synchronously during attach. Only record the
            // one-shot once the frame actually lands.
            DispatchQueue.main.async {
                // Upgrade safety (Codex P3 on d8c7ee2): if the window already
                // has a non-default frame, AppKit/SwiftUI has restored a saved
                // layout from a previous app version that pre-dates this
                // one-shot marker. Honor that frame and just record the marker
                // so future launches skip this branch entirely. Predicate is
                // pulled into a pure helper so the gating is unit-testable.
                let defaultSize = CGSize(width: 1360, height: 860)
                guard looksLikeSwiftUIDefaultSize(window.frame.size, defaultSize: defaultSize) else {
                    UserDefaults.standard.set(true, forKey: key)
                    return
                }
                guard let screen = window.screen ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                let width = min(defaultSize.width, visible.width - 80)
                let height = min(defaultSize.height, visible.height - 80)
                let frame = NSRect(x: visible.midX - width / 2,
                                   y: visible.midY - height / 2,
                                   width: width, height: height)
                window.setFrame(frame, display: true, animate: false)
                UserDefaults.standard.set(true, forKey: key)
            }
        }

        /// Pure helper that decides whether the window's current size matches
        /// the SwiftUI `defaultSize` (within a 1 pt tolerance) — i.e. SwiftUI
        /// has not yet been overridden by a restored frame. `nonisolated` so
        /// tests can call it without main-actor ceremony, and so the
        /// `applyInitialFrameIfNeeded` deferred block reaches it from the
        /// `DispatchQueue.main.async` closure (audit P3).
        nonisolated static func looksLikeSwiftUIDefaultSize(_ current: CGSize, defaultSize: CGSize) -> Bool {
            abs(current.width - defaultSize.width) < 1
                && abs(current.height - defaultSize.height) < 1
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

/// Extracted view to isolate high-frequency observation of `model.recordingElapsedSeconds`.
private struct RecordingElapsedView: View {
    let model: EditorModel

    var body: some View {
        let elapsed = formatElapsed(model.recordingElapsedSeconds)
        Text(elapsed)
            .font(.caption.monospacedDigit())
            .foregroundStyle(model.isPaused ? .orange : .red)
            .accessibilityLabel("\(model.isPaused ? "Paused" : "Recording") elapsed \(elapsed)")
    }
}

/// Isolates observation of `model.recordingDiskFreeBytes` and `model.recordingDiskWarning`
/// so the parent view is not invalidated by disk-space polling.
private struct RecordingDiskSpaceView: View {
    let model: EditorModel

    var body: some View {
        if let free = model.recordingDiskFreeBytes {
            Text("|")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.recordingDiskWarning == .warn ? .yellow : .secondary)
                .accessibilityLabel("Disk free: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
    }
}

/// Formats elapsed seconds as `mm:ss` or `h:mm:ss` when hours are nonzero.
func formatElapsed(_ seconds: Double) -> String {
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    let s = Int(seconds) % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

#Preview("Editor") {
    EditorView(model: EditorModel())
        .frame(width: 1180, height: 760)
}
