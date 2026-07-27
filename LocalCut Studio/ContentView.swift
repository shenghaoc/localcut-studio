import SwiftUI
import AppIntents
import AppKit
import UniformTypeIdentifiers
import LocalCutCore

/// Keeps App Intent routing stable while SwiftUI recreates the `App` value.
/// The shell marks the single process-wide editor ready when its window
/// appears; cold-launch intents wait for that readiness instead of requiring
/// a previously opened project file.
@MainActor
private enum LocalCutStudioAppState {
    static let model = EditorModel()
    static let editorRegistry = ActiveEditorRegistry()
    static let appIntentRouter = LocalCutAppIntentRouter(editorRegistry: editorRegistry)
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

    private var runsTimelineFocusUITestHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--localcut-ui-test-timeline-focus-harness")
            || ProcessInfo.processInfo.environment["LOCALCUT_UI_TEST_TIMELINE_FOCUS_HARNESS"] == "1"
    }

    private var runsTimelineViewUITestHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--localcut-ui-test-timeline-view-harness")
            || ProcessInfo.processInfo.environment["LOCALCUT_UI_TEST_TIMELINE_VIEW_HARNESS"] == "1"
    }
#endif

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if runsRecorderUITestHarness {
                RecorderUITestHarnessView()
                    .frame(minWidth: 420, minHeight: 320)
            } else if runsTimelineViewUITestHarness {
                TimelineViewUITestHarnessView()
                    .frame(minWidth: 1000, minHeight: 640)
            } else if runsTimelineFocusUITestHarness {
                TimelineFocusUITestHarnessView()
                    .frame(minWidth: 480, minHeight: 360)
            } else {
                editorView
            }
#else
            editorView
#endif
        }
        .defaultSize(width: 1360, height: 860)
        .defaultWindowPlacement { content, context in
            WindowPlacement(size: EditorWindowPlacement.fittedSize(
                idealSize: content.sizeThatFits(.unspecified),
                visibleRect: context.defaultDisplay.visibleRect
            ))
        }
        .windowIdealPlacement { content, context in
            WindowPlacement(size: EditorWindowPlacement.fittedSize(
                idealSize: content.sizeThatFits(.unspecified),
                visibleRect: context.defaultDisplay.visibleRect
            ))
        }
        .restorationBehavior(.automatic)
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
        EditorView(model: model, editorRegistry: LocalCutStudioAppState.editorRegistry)
            .frame(
                minWidth: EditorWindowPlacement.minimumContentSize.width,
                minHeight: EditorWindowPlacement.minimumContentSize.height)
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

            Button("Retake Last Recording") { [weak model] in
                Task { [weak model] in await model?.retakeRecording() }
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
    @FocusedBinding(\.localCutInspectorVisibility) private var inspectorVisible
    @FocusedValue(\.localCutTimelineDuration) private var timelineDuration

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle(isOn: Binding(
                get: { inspectorVisible ?? true },
                set: { inspectorVisible = $0 }
            )) {
                Text("Show Inspector")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(inspectorVisible == nil)

            Toggle(isOn: $model.isDiagnosticsVisible) {
                Text("Show Diagnostics")
            }
            .keyboardShortcut("d", modifiers: [.command, .option])

            Divider()

            // Transport in the menu bar so playback has a discoverable home.
            // The focused timeline handles Space with SwiftUI `onKeyPress`.
            // A bare menu key equivalent would be global in AppKit and swallow
            // spaces typed into text fields (e.g. the marker-rename popover).
            Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayPause() }
                .disabled((timelineDuration ?? 0) <= 0)
            Button("Go to Start") { model.seek(toSeconds: 0) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled((timelineDuration ?? 0) <= 0)
        }
    }
}

/// File and Edit menu items backed by the editor's custom document controller.
/// Actions intentionally use the process-wide model while focused values
/// supply scene presentation state. A future multi-editor shell must focus the
/// action target as well as its enablement state.
struct DocumentCommands: Commands {
    let model: EditorModel
    @FocusedValue(\.localCutInterchangeExport) private var interchangeExport
    @FocusedValue(\.localCutTimelineDuration) private var timelineDuration

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
                .disabled((timelineDuration ?? 0) <= 0)
            Divider()
            Button("Export Timeline (.otio)…") { interchangeExport?(.otio) }
                .disabled((timelineDuration ?? 0) <= 0 || interchangeExport == nil)
            Button("Export EDL (.edl)…") { interchangeExport?(.edl) }
                .disabled((timelineDuration ?? 0) <= 0 || interchangeExport == nil)
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
            Button("Split at Playhead") { model.splitSelectedClipAtPlayhead() }
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
            Button("Delete Transition") { model.removeSelectedTransition() }
                .disabled(model.selectedTransitionClipID == nil)
            // Mirror the destructive toolbar button so deleting a clip/transition
            // has a menu home; the scoped timeline handler owns the Delete key.
            Button("Delete Selected Clip") {
                if model.selectedTransitionClipID != nil {
                    model.removeSelectedTransition()
                } else {
                    model.deleteSelectedClip()
                }
            }
            .disabled(model.selectedClipID == nil && model.selectedTransitionClipID == nil)
            Divider()
            // No key equivalent here: the focused timeline owns the bare "m" key
            // through SwiftUI `onKeyPress`, which yields it to text fields. A
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
        Self.supportedRecentProjectURLs(from: NSDocumentController.shared.recentDocumentURLs)
    }

    static func supportedRecentProjectURLs(from urls: [URL]) -> [URL] {
        urls.filter(ProjectLocationInspector.isRecentProjectCandidate)
    }
}

/// Top-level editor layout: media bin · preview · inspector across the top, with
/// the timeline spanning the bottom. This is the native shell that mirrors the
/// browser editor's three-pane workspace.
struct EditorView: View {
    @Bindable var model: EditorModel
    let editorRegistry: ActiveEditorRegistry

    /// Presentation state belongs to a window, not to the project document or
    /// its runtime media engine. Scene storage scopes this value to the window
    /// and lets macOS restore it with the rest of the scene.
    @SceneStorage("editor.inspectorVisible") private var inspectorVisible = true
    @State private var pendingInterchangeExport: InterchangeExportRequest?
    @State private var isInterchangeExporterPresented = false
    @State private var isEdlTrackPickerPresented = false

    var body: some View {
        VSplitView {
            HSplitView {
                MediaBinView(model: model)
                    .frame(minWidth: 200, idealWidth: 240)

                PreviewView(model: model)
                    .frame(minWidth: 380)
                    .layoutPriority(1)

                if inspectorVisible {
                    EditorSideRailView(model: model) {
                        inspectorVisible = false
                    }
                    .frame(minWidth: 300, idealWidth: 340)
                } else {
                    CollapsedSideRailView {
                        inspectorVisible = true
                    }
                    .frame(width: 44)
                }
            }
            .frame(minHeight: 320)
            .background(SplitViewAutosaveConfigurator(autosaveName: "editor.workspace.columns",
                                                       isVertical: true,
                                                       isEnabled: inspectorVisible))

            TimelineView(model: model)
                .frame(minHeight: 200, idealHeight: 260)
        }
        .background(SplitViewAutosaveConfigurator(autosaveName: "editor.workspace.rows",
                                                   isVertical: false))
        .toolbar { toolbarContent }
        .navigationTitle(model.project.name)
        .safeAreaInset(edge: .bottom) { statusBar }
        .onAppear { [model] in
            editorRegistry.markReady(model)
            Task { [weak model] in await model?.scanRecoveredRecordings() }
        }
        .onDisappear {
            editorRegistry.markUnavailable(model)
            model.teardownAudioMetering()
        }
        .focusedSceneValue(\.localCutInspectorVisibility, $inspectorVisible)
        .focusedSceneValue(\.localCutInterchangeExport, InterchangeExportAction { kind in
            beginInterchangeExport(kind)
        })
        .focusedSceneValue(\.localCutTimelineDuration, model.totalDuration)
        .fileExporter(
            isPresented: $isInterchangeExporterPresented,
            document: pendingInterchangeExport?.document,
            contentType: pendingInterchangeExport?.contentType ?? .plainText,
            defaultFilename: pendingInterchangeExport?.defaultFilename
        ) { result in
            finishInterchangeExport(result)
        }
        .confirmationDialog(
            "Choose Video Track for EDL Export",
            isPresented: $isEdlTrackPickerPresented,
            titleVisibility: .visible
        ) {
            ForEach(model.project.videoTracks.indices, id: \.self) { index in
                let track = model.project.videoTracks[index]
                Button("\(track.name) (V\(index + 1))") {
                    prepareEdlExport(trackIndex: index)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("CMX3600 EDL exports a single video track.")
        }
        .sheet(isPresented: $model.isRecorderPresented) {
            RecorderSetupView(model: model)
        }
        .overlay {
            if model.isCountdownActive {
                RecordingCountdownView(model: model)
                    .transition(.opacity)
            }
        }
        .background(WindowConfigurator(model: model) {
            editorRegistry.markReady(model)
        })
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

    private func beginInterchangeExport(_ kind: InterchangeExportKind) {
        switch kind {
        case .otio:
            guard let request = model.makeOtioExportRequest() else { return }
            pendingInterchangeExport = request
            isInterchangeExporterPresented = true
        case .edl:
            guard !model.project.videoTracks.isEmpty else {
                model.statusMessage = String(localized: "No video tracks to export.")
                return
            }
            if model.project.videoTracks.count == 1 {
                prepareEdlExport(trackIndex: 0)
            } else {
                isEdlTrackPickerPresented = true
            }
        }
    }

    private func prepareEdlExport(trackIndex: Int) {
        guard let request = model.makeEdlExportRequest(trackIndex: trackIndex) else { return }
        pendingInterchangeExport = request
        isInterchangeExporterPresented = true
    }

    private func finishInterchangeExport(_ result: Result<URL, Error>) {
        guard let request = pendingInterchangeExport else { return }
        defer { pendingInterchangeExport = nil }
        switch result {
        case .success(let url):
            model.statusMessage = request.completedMessage(at: url)
        case .failure(let error):
            if let message = InterchangeExportErrorPresentation.statusMessage(for: error) {
                model.statusMessage = message
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
            .labelStyle(.iconOnly)
            .disabled(model.selectedClipID == nil)
            .help("Split clip at playhead")
            .accessibilityLabel("Split clip at playhead")

            Button {
                model.addTransitionToSelectedClip()
            } label: {
                Label("Add Transition", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .labelStyle(.iconOnly)
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
            .labelStyle(.iconOnly)
            .disabled(model.selectedClipID == nil && model.selectedTransitionClipID == nil)
            .help("Delete selected clip or transition")
            .accessibilityLabel("Delete selected clip or transition")

            if model.isRecording || model.isPaused {
                if model.isPaused {
                    Button { [weak model] in
                        Task { [weak model] in await model?.resumeRecording() }
                    } label: {
                        Label("Resume", systemImage: "play.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .help("Resume recording")
                    .accessibilityLabel("Resume recording")
                } else {
                    Button { [weak model] in
                        Task { [weak model] in await model?.pauseRecording() }
                    } label: {
                        Label("Pause", systemImage: "pause.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .help("Pause recording")
                    .accessibilityLabel("Pause recording")
                }
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .labelStyle(.iconOnly)
                .disabled(model.isStartingRecording || model.isPausingRecording || model.isStoppingRecording)
                .help("Stop recording")
                .accessibilityLabel("Stop recording")
            } else {
                Button {
                    model.requestRecorder()
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .labelStyle(.iconOnly)
                .disabled(model.isCountdownActive || model.isStartingRecording || model.isPausingRecording || model.isStoppingRecording)
                .help("Open recorder")
                .accessibilityLabel("Open recorder")

                if model.hasLastRecordingTake {
                    Button {
                        model.collapseRecordingGap()
                    } label: {
                        Label("Collapse Recording Gaps", systemImage: "arrow.left.and.right")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canCollapseRecordingGaps)
                    .help("Collapse pause gaps in the last recording")
                    .accessibilityLabel("Collapse pause gaps in the last recording")

                    Button { [weak model] in
                        Task { [weak model] in await model?.retakeRecording() }
                    } label: {
                        Label("Retake Last Recording", systemImage: "arrow.counterclockwise")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canRetakeRecording)
                    .help("Retake the last recording in the same timeline slot")
                    .accessibilityLabel("Retake the last recording in the same timeline slot")
                }
            }

            Button {
                inspectorVisible.toggle()
            } label: {
                Label(inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .labelStyle(.iconOnly)
            .help(inspectorVisible ? "Hide inspector panel" : "Show inspector panel")
            .accessibilityLabel(inspectorVisible ? "Hide inspector panel" : "Show inspector panel")

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
            .labelStyle(.iconOnly)
            .disabled(model.totalDuration <= 0)
            .help("Queue an export with the default preset.")
            .accessibilityLabel("Queue an export with the default preset.")
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
                        .foregroundStyle(.orange)
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .help(model.statusMessage)
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
            return .orange
        }
        return .secondary
    }

    private var relinkBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("\(model.unresolvedMedia.count) media file(s) need relinking.")
                .font(.caption)
            Button("Relink…") { [weak model] in
                Task { [weak model] in await model?.relinkNextMissingMedia() }
            }
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

/// The narrow AppKit bridge that remains while the macOS 26 custom file-based
/// controller owns asynchronous package saves. It mirrors the edited state,
/// protects close during recording or an async save, and marks the editor
/// window ready for App Intent routing. Scene APIs own placement and
/// restoration; no frame manipulation lives here.
struct WindowConfigurator: NSViewRepresentable {
    let model: EditorModel
    let onWindowActivated: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onWindowActivated: onWindowActivated)
    }

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
        coordinator.onWindowActivated = onWindowActivated
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
        var onWindowActivated: @MainActor () -> Void
        weak var window: NSWindow?
        /// Set only after the model's asynchronous save succeeds. The next
        /// programmatic close is allowed through without asking SwiftUI's
        /// original delegate to re-evaluate the already-confirmed close.
        private var permitsDeferredClose = false
        /// Previous window delegate, restored on detach.
        ///
        /// **Isolation invariant:** Set/read on `@MainActor` in `attach(to:)`;
        /// also read from nonisolated `responds(to:)` and
        /// `forwardingTarget(for:)` for AppKit delegate forwarding on the main
        /// thread, which Swift's actor model cannot express for Objective-C
        /// message forwarding.
        nonisolated(unsafe) weak var previousDelegate: NSWindowDelegate?

        init(model: EditorModel, onWindowActivated: @escaping @MainActor () -> Void) {
            self.model = model
            self.onWindowActivated = onWindowActivated
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
            }
            if window.isKeyWindow { onWindowActivated() }
            sync()
        }

        /// Mirrors the model's edited/URL state onto the window chrome.
        func sync() {
            window?.isDocumentEdited = model.isDirty
            window?.representedURL = model.documentURL
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if permitsDeferredClose {
                permitsDeferredClose = false
                return true
            }
            guard model.confirmClose(
                window: sender,
                // Retain this bridge until the asynchronous save completes.
                // SwiftUI may replace the representable while the alert's
                // close attempt is pending; a weak bridge would then drop the
                // only path that finishes the already-approved close.
                onSaveSucceeded: { [self, sender] in
                    guard self.window === sender else { return }
                    self.permitsDeferredClose = true
                    // `performClose(_:)` is a user-action simulation. In
                    // particular, SwiftUI's scene machinery can defer it
                    // after an asynchronous alert callback, leaving a clean
                    // saved document stranded in its window. The user has
                    // already made the close decision and the save succeeded,
                    // so close the window directly. Keep the one-shot permit
                    // for AppKit configurations that still ask the delegate
                    // while closing programmatically.
                    sender.close()
                }
            ) else { return false }
            // This bridge owns the close decision. A prior SwiftUI delegate
            // can veto an already-clean or already-confirmed close, which
            // would strand the document window after a successful save.
            return true
        }

        func windowDidBecomeKey(_ notification: Notification) {
            onWindowActivated()
            previousDelegate?.windowDidBecomeKey?(notification)
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
                .accessibilityHidden(true)
            Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.recordingDiskWarning == .warn ? .orange : .secondary)
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
    EditorView(model: EditorModel(), editorRegistry: ActiveEditorRegistry())
        .frame(width: 1180, height: 760)
}
