import Foundation
import AVFoundation
import CoreGraphics
import Observation
import LocalCutCore
import LocalCutDomain
import LocalCutPlatform

/// The single source of truth driving the editor UI: it owns the project, the
/// preview `AVPlayer`, the current selection, and the timeline view state, and it
/// rebuilds the composition whenever the arrangement changes.
///
/// ### Observation policy
///
/// `EditorModel` uses Swift's `@Observable` macro (Observation framework). Most
/// stored properties are automatically tracked so that SwiftUI views re-render
/// when they change. Each ignored property has a reason documented alongside
/// its owner. Common categories are stable services, framework handles,
/// task/observer lifetimes, cache bookkeeping, and operation guards.
///
/// **Cross-cutting notes:**
///
/// - **`nonisolated(unsafe)` overlap** — cleanup handles carry both
///   `@ObservationIgnored` and `nonisolated(unsafe)`: `silenceDetectionTask`,
///   `loudnessTask`, `timeObserver`, `endObserver`, `recordingMonitorTask`,
///   `beatAnalysisTask`, `activeOverlaySourceRegistryID`, `coalescedCommitTask`,
///   `recordingsFolderAccessURL`, `accessedURLs`, `bundleAccessURL`. The
///   `nonisolated(unsafe)` exists for `deinit` access; the `@ObservationIgnored`
///   exists because the properties are opaque handles or cleanup bookkeeping.
///   Neither annotation implies the other.
/// - **Task handles** include `coalescedCommitTask` for undo coalescing and
///   standalone cancellation handles for capture or analysis work.
/// - **`replayBufferManager`** is a framework object, not capture-internal
///   state. The UI reads it only while observed `isRecording` is true;
///   failed capture startup disables and releases the manager before returning
///   with `isRecording == false`, then clears ring storage asynchronously.
/// - **`closeSaveInProgress`** is a document/operation guard, separate
///   from capture state because it prevents duplicate asynchronous close-save
///   operations and is not rendered.
///
/// **When in doubt:** ask whether a SwiftUI view reads the property *directly*
/// (not via a computed wrapper or another observed property). If yes, the
/// property probably should NOT be ignored. If no, the annotation is likely
/// correct.
@Observable
@MainActor
final class EditorModel {

    let project = Project()

    /// Runtime audio master bus (P16). Owns the live + offline `AVAudioEngine`
    /// graphs and the peak/RMS meter snapshot; persistent parameters live on
    /// `project`. Created here so the inspector can bind to a stable instance
    /// for the editor's lifetime; live graph startup stays lazy so opening a
    /// project does not start audio hardware until metering or cleanup needs it.
    let audioBus = AudioMasterBus()

    /// Shared encoder budget for all hardware encoder consumers
    /// (export, capture, Program Mode). Created once per editor lifetime.
    let encoderBudget = EncoderBudget(
        maxConcurrent: Capabilities.current.videoEncoderCount > 0 ? 4 : 1)

    /// The active Program Mode session. Shared across all ProgramPanel
    /// instances to enforce the one-session invariant.
    var programSession: ProgramSession?

    /// The active WHIP publish session, if any. At most one publish session
    /// may be active at a time.
    var whipSession: WhipSession?
    var publishVideoTap: VideoPublishTap?
    var publishAudioBridge: AudioPublishBridge?
    var publishProgramFrameSinkID: UUID?

    /// Stored publish settings (endpoint, token, codec config).
    let publishSettings = PublishSettings()

    // Selection
    var selectedClipID: Clip.ID?
    var selectedMediaID: MediaItem.ID?
    /// The marker currently highlighted on the timeline ruler / inspector.
    /// `Delete` only removes a marker when this is set, so the existing
    /// clip / transition delete shortcut keeps working unchanged.
    var selectedMarkerID: TimelineMarker.ID?
    var selectedOverlayID: OverlayClip.ID?
    var selectedCalloutID: CalloutClip.ID?
    /// Phase 43 auto-zoom proposals from the event log.
    var autoZoomProposals: [ZoomPanProposal] = []
    /// Phase 44 silence detection proposals for review-before-apply.
    var silenceProposals: [ProposedCut] = []
    /// Tracks the in-flight silence detection task for cancellation.
    /// nonisolated(unsafe) so deinit can cancel from any thread.
    @ObservationIgnored nonisolated(unsafe) var silenceDetectionTask: Task<Void, Never>?
    /// Incremented on each detection invocation to prevent stale results.
    var silenceDetectionGeneration: Int = 0

    // Playback
    let player = AVPlayer()
    var isPlaying = false
    var hasPreviewItem = false
    /// Playhead position in seconds.
    var currentTime: Double = 0
    var totalDuration: Double = 0

    // Timeline view state
    var pixelsPerSecond: Double = 80

    /// Whether newly imported media should be copied into `.lcbundle` saves.
    /// Shared between the Media Bin toggle and the File ▸ Import… menu command
    /// so the user's preference is respected from either entry point.
    var copyImportsIntoBundle: Bool = true

    // Beat tools (Phase 34)
    /// Whether beat markers are shown on the timeline ruler. Session-only;
    /// reset on document open because beat analyses are project-scoped.
    var showBeatMarkers = false
    /// Whether clip editing snaps to beat boundaries. Session-only;
    /// reset on document open because beat analyses are project-scoped.
    var snapToBeats = false
    /// Global draw/snap offset in seconds, clamped by the inspector to ±200 ms.
    /// Changing it must drop the projected-beat memo so markers, snap targets,
    /// and cut/align reflect the new offset on the next read.
    var beatOffsetSeconds: Double = BeatToolsDefaults.offsetSeconds {
        didSet { invalidateProjectedBeatTimesCache() }
    }
    /// Maximum distance for Align to Beat in seconds.
    var beatAlignWindowSeconds: Double = BeatToolsDefaults.alignWindowSeconds
    /// Per-source beat analyses. Mutating this set (analysis completes, caches
    /// load, document reset) invalidates the projected-beat memo.
    var beatAnalyses: [MediaItem.ID: BeatAnalysis] = [:] {
        didSet { invalidateProjectedBeatTimesCache() }
    }

    // Scopes panel (colour-management feature) — session-only UI flag, not persisted.
    var showScopes: Bool = false
    var showSafeZones: Bool = false
    var selectedSafeZoneProfileID: String = SafeZoneLibrary.defaultProfileID

    // Status / export
    var statusMessage = "Import media to begin."

    /// Builds a user-visible failure message while keeping an underlying error
    /// and its recovery suggestion as separate sentences. Localized error
    /// descriptions are inconsistent about trailing punctuation, so callers
    /// should use this instead of interpolating an unconditional period.
    nonisolated static func failureStatusMessage(summary: String,
                                                  detail: String,
                                                  recoverySuggestion: String? = nil) -> String {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = detail.isEmpty ? summary : "\(summary): \(detail)"

        guard let recoverySuggestion else { return message }
        let recovery = recoverySuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recovery.isEmpty else { return message }
        if let finalCharacter = message.last,
           !".!?…".contains(finalCharacter) {
            message.append(".")
        }
        message += " \(recovery)"
        return message
    }

    /// Serial render queue, owned for the lifetime of the editor. Loaded once
    /// during init so a queue saved by the previous session resumes cleanly.
    /// Replaces the legacy `isExporting` / `exportProgress` fields — progress
    /// now lives on `renderQueue.totalProgress` and the per-job rows.
    let renderQueue: RenderQueue

    // Service objects — stable helpers that delegate to EditorModel.
    // Ignored: SwiftUI never renders their internal lifecycle state directly;
    // they write user-visible output to observed model properties.
    @ObservationIgnored private let importService = ImportService()
    @ObservationIgnored private let projectEditingService = ProjectEditingService()
    @ObservationIgnored private let previewRebuildCoordinator = PreviewRebuildCoordinator()
    @ObservationIgnored private let exportCoordinator = ExportCoordinator()
    @ObservationIgnored let documentController = DocumentController()
    @ObservationIgnored let captureCoordinator = CaptureCoordinator()

    // MARK: - Replay buffer (Phase 46)

    /// The replay buffer manager for the current recording session, if any.
    /// Ignored: UI only checks `!= nil` while observed `isRecording` is true.
    /// Failed capture startup disables and releases it immediately, then clears
    /// ring storage asynchronously.
    @ObservationIgnored var replayBufferManager: ReplayBufferManager?
    /// Whether the replay buffer is enabled for the current session.
    var replayBufferEnabled: Bool = false
    /// Current replay buffer duration setting.
    var replayBufferDuration: ReplayBufferConfig.DurationOption = .seconds30
    /// Whether a replay save is currently in progress.
    var replaySaveInProgress: Bool = false

    // Skin smoothing debug
    var showSkinMask = false

    /// Monotonic token guarding asynchronous loudness measurements. Bumped on any
    /// project mutation or document load (see `invalidateLoudnessMeasurement`), so
    /// a measurement that finishes after the project it measured has changed — an
    /// edit, a new target, or a different document — is discarded rather than
    /// writing a stale gain into the current project and undo stack.
    @ObservationIgnored var loudnessMeasurementToken = 0

    /// In-flight loudness measurement task. Cancelled on the next invocation
    /// to prevent concurrent full-composition decode + DSP operations.
    ///
    /// **Isolation invariant:** Mutated on `@MainActor`; read in `deinit`
    /// after the model has left normal main-actor workflows. The read only
    /// issues an idempotent `Task.cancel()`.
    @ObservationIgnored nonisolated(unsafe) var loudnessTask: Task<Void, Never>?

    /// Session cache of imported LUT filenames keyed by their bookmark, so the
    /// inspector can show a LUT's name without resolving the security-scoped
    /// bookmark on the main actor on every render. Not persisted; a LUT from a
    /// reopened project shows a generic label until re-imported.
    /// Ignored: read-only cache consumed by `selectedClipLUTName` and
    /// `selectedClipLUT(_:)` during inspector recomputation; the inspector already
    /// re-evaluates when the clip/selection changes.  Enabling observation would
    /// cause spurious churn on document restore (batch LUT import).
    @ObservationIgnored private(set) var lutDisplayNames: [Data: String] = [:]

    // Diagnostics
    /// Drives whether the diagnostics overlay is on screen and whether the
    /// `DiagnosticsAgent`'s 1 Hz timer is sampling. Hidden by default so a
    /// long-running export doesn't pay the probe cost.
    var isDiagnosticsVisible = false {
        didSet { syncDiagnosticsLifecycle() }
    }
    let diagnostics: DiagnosticsAgent

    // Capture engine (Phase 41)
    var isRecorderPresented = false
    var isStartingRecording = false
    var isRecording = false
    var isPausingRecording = false
    var isStoppingRecording = false
    var hideFloatingPanelWhileRecording = false
    var recordingStartedAt: Date?
    var recordingElapsedSeconds: Double = 0
    var recordingDiskFreeBytes: Int64?
    var recordingDiskWarning: RecordingDiskWarning?
    var recordingSourceCount: Int = 0
    var recordingBackpressureCount: Int = 0
    var recordingIncludesMicrophone = false
    var recordingMicLevel: Float = 0
    var recordingLiveMonitorLatencyMs: Double = 0
    var recoveredCaptureSessions: [CaptureSessionResult] = []
    /// Security-scoped URL for the recordings folder. Owned by `EditorModel`;
    /// updated on `@MainActor` recording setup/teardown and stopped in `deinit`.
    ///
    /// **Isolation invariant:** Normal isolation cannot express this final
    /// nonisolated cleanup read, but the model is no longer reachable by
    /// main-actor workflows during `deinit`; the read only balances any
    /// remaining security-scoped grant.
    @ObservationIgnored nonisolated(unsafe) var recordingsFolderAccessURL: URL?
    /// In-flight recording monitor task. Cancelled in `deinit` for cleanup.
    ///
    /// **Isolation invariant:** All runtime reads/writes occur on `@MainActor`.
    /// `nonisolated(unsafe)` allows the nonisolated `deinit` to cancel it;
    /// task cancellation is idempotent.
    @ObservationIgnored nonisolated(unsafe) var recordingMonitorTask: Task<Void, Never>?
    /// Accumulated wall-clock time spent paused, subtracted from elapsed display.
    /// Ignored: consumed only by `recordingElapsedSeconds` computation; the
    /// elapsed-seconds readout IS observed.
    @ObservationIgnored var recordingPausedDuration: TimeInterval = 0
    /// Wall-clock time when the current pause started, or nil if not paused.
    @ObservationIgnored var pauseStartedAt: Date?

    // Phase 42 — Recorder UX
    var isCountdownActive = false
    var countdownSeconds = 3
    var countdownRemaining = 0
    var isPaused = false
    var hasLastRecordingTake = false
    // Retake / recording-landing plumbing — ignored because the UI-facing flags
    // (isRecording, isPaused, hasLastRecordingTake, activePiPPreset) are observed;
    // these backing fields are only consumed by capture/retake logic.
    /// Stored request for retake: replaces the most recent chunk-set in the same
    /// timeline slot.
    @ObservationIgnored var lastRecordingRequest: CaptureStartRequest?
    /// Tracks the timeline slots occupied by the most recent recording landing,
    /// so retake can replace them without touching unrelated tracks.
    /// Ignored: consumed only by capture/retake logic; the UI reads
    /// `hasLastRecordingTake` (observed) instead. (`RecorderUITestHarnessView`
    /// reads `.isEmpty` directly, but that view is `#if DEBUG` only.)
    @ObservationIgnored var lastRecordingSlots: [RecordingSlot] = []
    /// When set, `landCaptureSession` uses these positions instead of capture PTS
    /// so a retake lands in the original timeline slot.
    @ObservationIgnored var retakeTimelinePositions: [RecordingSlotKey: CMTime] = [:]
    /// Captured before a retake removes the old chunk set; landing registers one
    /// undo step spanning both removal and replacement.
    @ObservationIgnored var retakeUndoBefore: ProjectState?
    @ObservationIgnored var retakePreviousSlots: [RecordingSlot] = []
    /// Track indices from the original recording, keyed by source/chunk, so
    /// retake can reinsert each replacement track at the same stack position.
    @ObservationIgnored var retakeTrackIndices: [RecordingSlotKey: Int] = [:]
    /// PiP preset applied to webcam tracks.
    var activePiPPreset: PiPPreset?
    /// Snapshot of the PiP preset from the last recording, for retake restores.
    /// Ignored: backing field for retake logic; `activePiPPreset` IS observed.
    @ObservationIgnored var lastRecordingPiPPreset: PiPPreset?
    /// Floating control panel controller.
    @ObservationIgnored let floatingPanelController = FloatingPanelController()

    /// AVPlayer time observer. Installed on `@MainActor`, removed in `deinit`.
    ///
    /// **Isolation invariant:** `removeTimeObserver` is thread-safe; `deinit`
    /// access is benign.
    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    /// AVPlayer end-of-item observer. Installed on `@MainActor`, removed in `deinit`.
    ///
    /// **Isolation invariant:** `NotificationCenter.removeObserver` is
    /// thread-safe; `deinit` access is benign.
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    @ObservationIgnored let beatAnalyzer = BeatAnalyzer()
    // Beat-analysis cache — ignored: these are memoisation plumbing for
    // `projectedBeatTimes`; the UI reads the computed output, not these tokens.
    /// In-flight beat-analysis task.
    ///
    /// **Isolation invariant:** Owned and mutated by `EditorModel` on
    /// `@MainActor`; read in nonisolated `deinit` only to issue idempotent task
    /// cancellation after the model has left normal main-actor workflows.
    @ObservationIgnored nonisolated(unsafe) var beatAnalysisTask: Task<Void, Never>?
    @ObservationIgnored var beatAnalysisKeys: [MediaItem.ID: String] = [:]
    @ObservationIgnored var cachedProjectedBeatTimes: [CMTime] = []
    @ObservationIgnored var projectedBeatTimesRevision: Int = 0
    @ObservationIgnored var lastProjectedBeatTimesRevision: Int = -1
    /// Active overlay source registry ID for the current preview.
    ///
    /// **Isolation invariant:** Mutated on `@MainActor`; read in `deinit`
    /// (nonisolated) for resource cleanup via `EffectCompositor.releaseOverlaySources`.
    @ObservationIgnored nonisolated(unsafe) var activeOverlaySourceRegistryID: UUID?

    // MARK: - Clip lookup index

    /// O(1) clip lookup: maps clip ID to (trackKind, trackIndex, clipIndex).
    /// Rebuilt on every project mutation via `rebuildClipIndex()`.
    /// Ignored: derived lookup cache; UI observes the project mutations that
    /// invalidate and rebuild it, never the index itself.
    @ObservationIgnored private var clipIndex: [Clip.ID: (trackKind: TrackKind, trackIndex: Int, clipIndex: Int)] = [:]

    /// Rebuilds the clip index from the current project state.
    func rebuildClipIndex() {
        var index: [Clip.ID: (trackKind: TrackKind, trackIndex: Int, clipIndex: Int)] = [:]
        for (ti, track) in project.videoTracks.enumerated() {
            for (ci, clip) in track.clips.enumerated() {
                index[clip.id] = (.video, ti, ci)
            }
        }
        for (ti, track) in project.audioTracks.enumerated() {
            for (ci, clip) in track.clips.enumerated() {
                index[clip.id] = (.audio, ti, ci)
            }
        }
        clipIndex = index
    }

    // MARK: Document state
    /// The current document's local filesystem URL and storage representation
    /// move together so Save cannot observe only half of the session identity.
    var projectSessionLocation: ProjectSessionLocation = .unsaved
    var documentURL: URL? { projectSessionLocation.url }
    var projectStorageKind: ProjectStorageKind? { projectSessionLocation.storageKind }
    /// Whether the project has unsaved changes (drives the window's edited dot).
    var isDirty = false
    /// True while a window-close Save choice is already writing asynchronously.
    /// Ignored: transient guard; not user-visible (close is blocked while true).
    @ObservationIgnored var closeSaveInProgress = false
    /// Media references whose files couldn't be resolved on open; awaiting relink.
    var unresolvedMedia: [MediaRef] = []
    /// SHA-256 of every bundled asset as of the last successful bundle read or
    /// write. Used by the next bundle save's fast path to skip re-copying media
    /// whose source hasn't changed since the previous save.
    /// Ignored: internal bookkeeping for bundle save optimisation; never rendered.
    @ObservationIgnored var lastBundleFingerprints = FingerprintIndex()

    // MARK: Undo state
    @ObservationIgnored let undoManager = UndoManager()
    var canUndo = false
    var canRedo = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"
    // Undo coalescing plumbing — ignored: user-visible state (canUndo, canRedo,
    // undoTitle, redoTitle, isDirty) is observed; these are gesture-internal snapshots.
    @ObservationIgnored var coalescedUndoBefore: ProjectState?
    @ObservationIgnored var coalescedUndoName: String?
    @ObservationIgnored var coalescedUndoTarget: AnyHashable?
    /// nonisolated(unsafe) so deinit can cancel from any thread.
    @ObservationIgnored nonisolated(unsafe) var coalescedCommitTask: Task<Void, Never>?
    /// `isDirty` at the start of the current coalesced gesture, restored if the
    /// gesture settles with no net change (so a no-op edit doesn't prompt to save).
    @ObservationIgnored var coalescedUndoWasDirty = false

    /// Monotonically increases on every mutation; lets an async save tell whether
    /// the project changed between snapshotting its data and finishing the write.
    /// Ignored: monotonic token for stale-cancellation; never rendered.
    @ObservationIgnored var mutationRevision = 0

    /// Security-scoped resources retained for the session, stopped on teardown.
    /// Holds **per-file** bookmark-resolved URLs only — never the outer
    /// `.lcbundle` directory URL. The bundle's grant lives on
    /// `bundleAccessURL` so `reconcileAccessedURLs` (which compares this set
    /// to `project.mediaItems.map(\.url)`) can't accidentally revoke it on
    /// undo/redo (the bundle URL is never equal to any media item URL —
    /// item URLs point at files *inside* the bundle).
    ///
    /// **Isolation invariant:** Mutated on `@MainActor`; iterated in nonisolated
    /// `deinit` after the model has left normal main-actor workflows. The read
    /// is only for balancing remaining security-scoped grants.
    // Security-scoped access bookkeeping — ignored: these URLs exist only for
    // `start/stopAccessingSecurityScopedResource()` in `deinit`; never rendered.
    @ObservationIgnored nonisolated(unsafe) var accessedURLs: Set<URL> = []

    /// Security-scoped access on the outer `.lcbundle` directory, when the
    /// current document is a bundle. Tracked separately from `accessedURLs`
    /// for the reason in that property's doc. Stopped on session teardown.
    ///
    /// **Isolation invariant:** Mutated on `@MainActor`; read from nonisolated
    /// teardown only to balance a remaining bundle security-scoped grant.
    @ObservationIgnored nonisolated(unsafe) var bundleAccessURL: URL?

    /// Bumped on every session swap (New/Open). Async import/relink capture it
    /// and bail if it changes across their awaits, so work started for one
    /// document can neither leak security-scoped access nor land clips in another.
    /// Ignored: monotonic token for stale-cancellation; never rendered.
    @ObservationIgnored var sessionGeneration = 0

    init() {
        // Initialise the render queue first — it's the one `let` without an
        // inline default, so it must be set before any other access on self.
        self.renderQueue = RenderQueue()
        renderQueue.encoderBudget = encoderBudget
        let audioBus = self.audioBus
        renderQueue.setOfflineMeterSink(
            audioBus.offlineMeterSnapshotPublisher,
            activity: { active in
                audioBus.setOfflineMeteringActive(active)
            })

        // Each editor action manages its own undo group explicitly, so disable
        // run-loop-based coalescing (see registerUndo).
        undoManager.groupsByEvent = false

        // The diagnostics agent needs to read the project's frame rate (for the
        // GPU-utilisation proxy) and the player's dropped-frame counter. We
        // can't capture `self` strongly here without a retain cycle, but `weak
        // self` is fine — the agent only outlives the editor briefly during
        // deinit, and the closures return a sensible default in that window.
        let project = self.project
        let player = self.player
        self.diagnostics = DiagnosticsAgent(
            frameDuration: { 1.0 / max(1, project.frameRate) },
            droppedFramesProvider: {
                let log = player.currentItem?.accessLog()
                return log?.events.last?.numberOfDroppedVideoFrames ?? 0
            })

        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main) { [weak self] notification in
            // Read the (non-Sendable) notification on the delivery queue (.main)
            // before entering assumeIsolated; capturing it inside the isolated
            // closure would be a Swift 6 "sending risks data races" error.
            guard notification.object as? AVPlayerItem == self?.player.currentItem else { return }
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.audioBus.pauseLivePreview()
            }
        }

        // Restore any jobs persisted from the previous session and resume the
        // runner (running jobs are rewound to queued; stale bookmarks flip to
        // failed — see RenderQueue.reconcile).
        renderQueue.load()
    }

    deinit {
        previewRebuildCoordinator.cancelAll()
        beatAnalysisTask?.cancel()
        recordingMonitorTask?.cancel()
        silenceDetectionTask?.cancel()
        coalescedCommitTask?.cancel()
        loudnessTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        EffectCompositor.releaseOverlaySources(for: activeOverlaySourceRegistryID)
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        bundleAccessURL?.stopAccessingSecurityScopedResource()
        recordingsFolderAccessURL?.stopAccessingSecurityScopedResource()
    }

    /// Starts or stops the diagnostics agent to match the panel's visibility.
    private func syncDiagnosticsLifecycle() {
        if isDiagnosticsVisible { diagnostics.start() } else { diagnostics.stop() }
    }

    // MARK: - Import

    /// Loads the given files into the media bin, reading metadata and a poster
    /// frame for each. Security-scoped access is retained for the session.
    func importMedia(urls: [URL], wantsBundling: Bool = true) async -> EditorCommandOutcome {
        await importService.importMedia(urls: urls, wantsBundling: wantsBundling, model: self)
    }

    // MARK: - Timeline editing

    /// Appends a media item to the end of the timeline (ripple-append) on the
    /// first video and/or audio track, depending on what the media contains.
    func addToTimeline(mediaID: MediaItem.ID) {
        projectEditingService.addToTimeline(mediaID: mediaID, model: self)
    }

    /// All tracks, flattened, for lookups.
    private var allTracks: [Track] { project.videoTracks + project.audioTracks }

    func deleteSelectedClip() {
        projectEditingService.deleteSelectedClip(model: self)
    }

    /// Removes a media item and its orphaned clips, then stops its security-scoped access.
    func removeMedia(itemID: MediaItem.ID) {
        projectEditingService.removeMedia(itemID: itemID, model: self)
    }

    /// Splits the selected clip at the current playhead into two adjacent clips.
    func splitSelectedClipAtPlayhead() {
        projectEditingService.splitSelectedClipAtPlayhead(model: self)
    }

    /// Mutates the selected clip via the supplied closure and schedules a
    /// debounced rebuild, coalescing a continuous gesture (opacity/colour drag)
    /// into a single undo step labelled `actionName`.
    func updateSelectedClipCoalesced(_ actionName: String = "Adjust Clip",
                                     _ transform: @escaping (inout Clip) -> Void) {
        projectEditingService.updateSelectedClipCoalesced(actionName, model: self, transform)
    }

    func rebuildDebounced(after delay: Duration = .milliseconds(200)) {
        previewRebuildCoordinator.rebuildDebounced(after: delay, model: self)
    }

    /// Starts a preview rebuild, cancelling any rebuild already in flight so the
    /// most recent project state is the one that reaches the player.
    ///
    /// Every clip-geometry change (trim, move, split, delete, cut/align, undo,
    /// redo, persistence reload) funnels through here, so this is also the
    /// single chokepoint that drops the projected-beat memo when the timeline
    /// layout the beats project through changes.
    func scheduleRebuild() {
        rebuildClipIndex()
        invalidateProjectedBeatTimesCache()
        previewRebuildCoordinator.scheduleRebuild(model: self)
    }

    func cancelPreviewRebuilds() {
        previewRebuildCoordinator.cancelAll()
    }

    // MARK: - Colour grading

    /// Returns the colour grade for the selected clip, inserting a neutral one if absent.
    var selectedClipGrade: ColourGrade {
        get {
            guard let clip = selectedClip else { return .neutral }
            if let effect = clip.effects.first(where: { if case .colourGrade = $0 { return true }; return false }),
               case .colourGrade(let g) = effect {
                return g
            }
            return .neutral
        }
        set {
            guard let id = selectedClipID else { return }
            performCoalescedUndoable("Adjust Colour", target: id, rebuild: .debounced) {
                for track in allTracks {
                    guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                    var grade = newValue
                    grade.clamp()
                    if let effectIndex = track.clips[index].effects.firstIndex(where: {
                        if case .colourGrade = $0 { return true }; return false
                    }) {
                        track.clips[index].effects[effectIndex] = .colourGrade(grade)
                    } else {
                        track.clips[index].effects.append(.colourGrade(grade))
                    }
                    RenderCache.shared.invalidate(clipID: id)
                    return
                }
            }
        }
    }

    /// Removes only the *colour* effects (`colourGrade` + `lut`) from the
    /// selected clip. An earlier version called `effects.removeAll()`
    /// unconditionally, which silently wiped non-colour effects like
    /// `skinSmooth` when the user clicked Reset on the Colour section —
    /// surprising data loss. Mirrors the per-effect filter used in
    /// `resetClipSkinSmooth()`.
    func resetClipColourEffects() {
        guard let id = selectedClipID else { return }
        performUndoable("Reset Colour") {
            for track in allTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                track.clips[index].effects.removeAll { effect in
                    switch effect {
                    case .colourGrade, .lut: true
                    case .skinSmooth, .grain, .halation, .vignette: false
                    }
                }
                RenderCache.shared.invalidate(clipID: id)
                scheduleRebuild()
                return
            }
        }
    }

    /// Imports a .cube LUT file and attaches it as a LUT effect on the selected clip.
    func importLUT(url: URL) {
        guard let id = selectedClipID,
              let selectedTrack = track(for: id),
              selectedTrack.kind == .video else {
            statusMessage = "Select a video clip before importing a LUT."
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            statusMessage = "Could not access \(url.lastPathComponent). Grant permission in System Settings > Privacy & Security > Files and Folders, then try again."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            statusMessage = "Could not store access to \(url.lastPathComponent). Try reopening the file after restarting the app."
            return
        }

        performUndoable("Import LUT") {
            for track in allTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                // Remember the filename now (we already hold the URL) so the
                // inspector never resolves the bookmark on the main actor just
                // to display it.
                lutDisplayNames[bookmark] = url.lastPathComponent
                // Replace the existing LUT slot rather than stacking a second
                // cube — a clip carries one LUT (R1.2).
                track.clips[index].effects = track.clips[index].effects.replacingLUT(bookmark: bookmark)
                pruneLUTDisplayNames()
                RenderCache.shared.invalidate(clipID: id)
                statusMessage = "Imported LUT \(url.lastPathComponent)."
                scheduleRebuild()
                return
            }
        }
    }

    /// Whether the selected clip currently has a LUT applied — drives the
    /// inspector's LUT indicator + remove control.
    var selectedClipHasLUT: Bool {
        selectedClip?.effects.hasLUT ?? false
    }

    /// Display filename of the selected clip's LUT, read from the session cache
    /// populated at import. Returns nil when no LUT is applied or the LUT came
    /// from a reopened project (no cached name) — the inspector then shows a
    /// generic "Applied" label. Deliberately does **not** resolve the bookmark
    /// here: that can block the main actor for LUTs on slow / network volumes.
    var selectedClipLUTName: String? {
        guard let clip = selectedClip else { return nil }
        for effect in clip.effects {
            guard case .lut(let bookmark) = effect else { continue }
            return lutDisplayNames[bookmark]
        }
        return nil
    }

    /// Removes only the LUT effect from the selected clip, leaving the colour
    /// grade and skin-smooth effects in place.
    func removeLUT() {
        guard let id = selectedClipID else { return }
        performUndoable("Remove LUT") {
            for track in allTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                track.clips[index].effects = track.clips[index].effects.removingLUT()
                pruneLUTDisplayNames()
                RenderCache.shared.invalidate(clipID: id)
                statusMessage = "Removed LUT."
                scheduleRebuild()
                return
            }
        }
    }

    func pruneLUTDisplayNames() {
        let activeBookmarks = Set(allTracks.flatMap(\.clips).flatMap { clip in
            clip.effects.compactMap { effect -> Data? in
                guard case .lut(let bookmark) = effect else { return nil }
                return bookmark
            }
        })
        lutDisplayNames = lutDisplayNames.filter { activeBookmarks.contains($0.key) }
    }

    func restoreLUTDisplayNames(_ names: [Data: String]) {
        lutDisplayNames = names
        pruneLUTDisplayNames()
    }

    #if DEBUG
    var _testLUTDisplayNameCacheCount: Int {
        lutDisplayNames.count
    }

    func _testCacheLUTDisplayName(_ name: String, for bookmark: Data) {
        lutDisplayNames[bookmark] = name
    }

    func _testPruneLUTDisplayNames() {
        pruneLUTDisplayNames()
    }
    #endif

    // MARK: - Time remapping

    var selectedClipOutputDuration: CMTime {
        selectedClip?.outputDuration ?? .zero
    }

    var selectedClipSpeedAtPlayhead: Float {
        guard let time = selectedClipSourceLocalPlayheadTime else {
            return selectedClip?.speedCurve.defaultValue ?? TimeRemapping.identitySpeed
        }
        guard let curve = selectedClip?.speedCurve else { return TimeRemapping.identitySpeed }
        return TimeRemapping.speedValue(in: curve, at: time)
    }

    var selectedClipSpeedKeyframeAtPlayhead: Keyframe<Float>? {
        guard let time = selectedClipSourceLocalPlayheadTime else { return nil }
        return nearestSpeedKeyframe(to: time)
    }

    var hasPreviousSelectedClipSpeedKeyframe: Bool {
        guard let clip = selectedClip,
              let localTime = selectedClipSourceLocalPlayheadTime else { return false }
        return previousSelectedClipSpeedKeyframe(in: clip, before: localTime) != nil
    }

    var hasNextSelectedClipSpeedKeyframe: Bool {
        guard let clip = selectedClip,
              let localTime = selectedClipSourceLocalPlayheadTime else { return false }
        return nextSelectedClipSpeedKeyframe(in: clip, after: localTime) != nil
    }

    /// Source-local time at the playhead for the selected clip, or nil when the
    /// playhead falls outside the clip's authored range. Maps the output-domain
    /// playhead back through the speed curve to clip-source time. Shared by the
    /// speed and skin-smooth keyframe authoring paths so the two can't drift.
    var selectedClipSourceLocalPlayheadTime: CMTime? {
        guard let clip = selectedClip else { return nil }
        // `currentTime` is effective (rippled) time; convert it to authored time
        // via the layout's authored-times mapping. Using `shift(at:)` with the
        // clip's start would assume a constant shift across the entire clip, but
        // a transition cut *inside* the clip changes the shift for later pieces.
        // `authoredTimes` returns every authored time that draws at this effective
        // time, so we pick the one that falls within the selected clip's authored
        // range.
        let cuts = TransitionLayout.cuts(videoTracks: project.videoTracks.map(\.clips))
        let playheadEffective = CMTime(seconds: currentTime, preferredTimescale: 600)
        let candidates = TransitionLayout.authoredTimes(forEffective: playheadEffective, cuts: cuts)
        guard let playhead = candidates.first(where: { $0 >= clip.timelineStart && $0 <= clip.timelineEnd }) else { return nil }
        let outputOffset = CMTimeMaximum(.zero, CMTimeMinimum(playhead - clip.timelineStart, clip.outputDuration))
        return clip.sourceOffset(forOutputOffset: outputOffset)
    }

    func updateSelectedClipTimeRemap(_ actionName: String = "Adjust Speed",
                                     invalidateVideo: Bool = true,
                                     _ transform: @escaping (inout Clip) -> Void) {
        guard let id = selectedClipID else { return }
        performCoalescedUndoable(actionName, target: id, rebuild: .debounced) {
            mutateClip(id: id, invalidateVideo: invalidateVideo, transform)
            self.invalidateProjectedBeatTimesCache()
        }
    }

    func updateSelectedClipTimeRemapDiscrete(_ actionName: String,
                                             invalidateVideo: Bool = true,
                                             _ transform: (inout Clip) -> Void) {
        guard let id = selectedClipID else { return }
        performUndoable(actionName) {
            mutateClip(id: id, invalidateVideo: invalidateVideo, transform)
            self.invalidateProjectedBeatTimesCache()
            scheduleRebuild()
        }
    }

    func addOrUpdateSelectedClipSpeedKeyframe() {
        guard let id = selectedClipID,
              let localTime = selectedClipSourceLocalPlayheadTime,
              let clip = selectedClip else {
            statusMessage = "Move the playhead over the selected clip to add a speed keyframe."
            return
        }

        let isUpdating = selectedClipSpeedKeyframeAtPlayhead != nil
        let value = clip.speedCurve.defaultValue
        updateSelectedClipTimeRemapDiscrete(
            isUpdating ? "Update Speed Keyframe" : "Add Speed Keyframe") { clip in
                upsertSpeedKeyframe(on: &clip, at: localTime, value: value)
            }
        statusMessage = "Speed keyframe set at \(TimeFormatting.timecode(localTime.seconds))."
        selectedClipID = id
        selectedOverlayID = nil
    }

    func removeSelectedClipSpeedKeyframe() {
        guard let keyframe = selectedClipSpeedKeyframeAtPlayhead else {
            statusMessage = "No speed keyframe at the playhead."
            return
        }

        updateSelectedClipTimeRemapDiscrete("Remove Speed Keyframe") { clip in
            removeSpeedKeyframe(on: &clip, near: keyframe.time)
        }
        statusMessage = "Removed speed keyframe."
    }

    func seekToPreviousSelectedClipSpeedKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipSourceLocalPlayheadTime,
              let previous = previousSelectedClipSpeedKeyframe(
                in: clip,
                before: localTime) else { return }
        let outputOffset = clip.outputOffset(forSourceOffset: previous.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    func seekToNextSelectedClipSpeedKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipSourceLocalPlayheadTime,
              let next = nextSelectedClipSpeedKeyframe(
                in: clip,
                after: localTime) else { return }
        let outputOffset = clip.outputOffset(forSourceOffset: next.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    func resetSelectedClipSpeed() {
        updateSelectedClipTimeRemapDiscrete("Reset Speed") { clip in
            clip.speedCurve = TimeRemapping.identitySpeedCurve
            clip.preservePitch = true
            clip.pitchAlgorithm = .timeDomain
        }
    }

    private var speedKeyframeHitToleranceSeconds: Double {
        0.5 / max(1, project.frameRate)
    }

    private func previousSelectedClipSpeedKeyframe(
        in clip: Clip,
        before localTime: CMTime
    ) -> Keyframe<Float>? {
        let tolerance = speedKeyframeHitToleranceSeconds
        return clip.speedCurve.keyframes.last {
            $0.time.seconds < localTime.seconds - tolerance
        }
    }

    private func nextSelectedClipSpeedKeyframe(
        in clip: Clip,
        after localTime: CMTime
    ) -> Keyframe<Float>? {
        let tolerance = speedKeyframeHitToleranceSeconds
        return clip.speedCurve.keyframes.first {
            $0.time.seconds > localTime.seconds + tolerance
        }
    }

    private func nearestSpeedKeyframe(to time: CMTime) -> Keyframe<Float>? {
        guard let curve = selectedClip?.speedCurve else { return nil }
        return nearestSpeedKeyframe(in: curve, to: time)
    }

    private func nearestSpeedKeyframe(in curve: Keyframed<Float>, to time: CMTime) -> Keyframe<Float>? {
        let tolerance = speedKeyframeHitToleranceSeconds
        return curve.keyframes
            .map { keyframe in (keyframe, abs((keyframe.time - time).seconds)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func upsertSpeedKeyframe(on clip: inout Clip, at time: CMTime, value: Float) {
        if let existing = nearestSpeedKeyframe(in: clip.speedCurve, to: time) {
            clip.speedCurve.updateKeyframe(id: existing.id, time: time, value: value)
        } else {
            clip.speedCurve.addKeyframe(at: time, value: value)
        }
        clip.clampTimeRemap()
    }

    private func removeSpeedKeyframe(on clip: inout Clip, near time: CMTime) {
        guard let existing = nearestSpeedKeyframe(in: clip.speedCurve, to: time) else { return }
        clip.speedCurve.removeKeyframe(id: existing.id)
        clip.clampTimeRemap()
    }

    func effectiveTimelineTime(forAuthored authored: CMTime) -> CMTime {
        let cuts = TransitionLayout.cuts(videoTracks: project.videoTracks.map(\.clips))
        return authored - TransitionLayout.shift(at: authored, cuts: cuts)
    }

    private func mutateClip(id: Clip.ID,
                            invalidateVideo: Bool,
                            _ transform: (inout Clip) -> Void) {
        guard let (track, index) = trackAndIndex(of: id) else { return }
        applyRetime(on: track, index: index, invalidateVideo: invalidateVideo, transform)

        // Linked A/V: a media item carrying both streams is placed as paired
        // clips on sibling tracks (same media + range). Retime the matching clip
        // so audio and video keep the same length and stay in sync — without this,
        // editing one side drifts the other past the picture.
        let edited = track.clips[index]
        if let pairID = pairedClipID(for: edited, ownerKind: track.kind),
           let (pairTrack, pairIndex) = trackAndIndex(of: pairID) {
            applyRetime(on: pairTrack, index: pairIndex, invalidateVideo: invalidateVideo, transform)
        }
    }

    /// Applies a time-remap `transform` to the clip at `index` on `track`, clamps
    /// it, then preserves the track's non-overlap/adjacency invariant: a speed
    /// change alters the clip's timeline length, so later clips ripple by the
    /// delta and transitions whose cut is no longer adjacent are dropped.
    private func applyRetime(on track: Track,
                             index: Int,
                             invalidateVideo: Bool,
                             _ transform: (inout Clip) -> Void) {
        let speedBefore = track.clips[index].speedCurve
        let sourceStartBefore = track.clips[index].sourceStart
        let sourceDurationBefore = track.clips[index].duration
        let outputBefore = track.clips[index].outputDuration
        transform(&track.clips[index])
        track.clips[index].clampTimeRemap()
        let outputAfter = track.clips[index].outputDuration
        if fabs(outputAfter.seconds - outputBefore.seconds) > 0.0001 {
            rippleDownstream(on: track, after: track.clips[index], by: outputAfter - outputBefore)
            sanitizeTransitions()
        }
        if invalidateVideo, track.clips[index].speedCurve != speedBefore {
            let edited = track.clips[index]
            if edited.sourceStart == sourceStartBefore,
               edited.duration == sourceDurationBefore,
               let localRange = TimeRemapping.affectedSourceRange(
                before: speedBefore,
                after: edited.speedCurve,
                sourceDuration: edited.duration) {
                RenderCache.shared.invalidate(
                    clipID: edited.id,
                    timeRange: CMTimeRange(
                        start: edited.sourceStart + localRange.start,
                        duration: localRange.duration))
            } else {
                RenderCache.shared.invalidate(clipID: edited.id)
            }
        }
    }

    /// The track and index hosting `id`, or nil if not found.
    private func trackAndIndex(of id: Clip.ID) -> (track: Track, index: Int)? {
        for track in allTracks {
            if let index = track.clips.firstIndex(where: { $0.id == id }) {
                return (track, index)
            }
        }
        return nil
    }

    /// Shifts every clip that starts after `clip` on `track` by `delta`, keeping
    /// the tail's spacing while removing the overlap (delta > 0) or gap (delta < 0)
    /// a length change introduced. Starts are clamped to the timeline origin.
    private func rippleDownstream(on track: Track, after clip: Clip, by delta: CMTime) {
        guard delta != .zero else { return }
        let pivot = clip.timelineStart
        for i in track.clips.indices where track.clips[i].id != clip.id {
            if track.clips[i].timelineStart > pivot {
                track.clips[i].timelineStart = CMTimeMaximum(.zero, track.clips[i].timelineStart + delta)
            }
        }
    }

    /// The id of the clip on the sibling track that mirrors `clip` (same media and
    /// source/timeline range) when the media carries both video and audio. Used to
    /// keep linked A/V retimes in sync.
    private func pairedClipID(for clip: Clip, ownerKind: TrackKind) -> Clip.ID? {
        guard let media = project.media(for: clip.mediaID), media.hasVideo, media.hasAudio else { return nil }
        let siblingKind: TrackKind = ownerKind == .video ? .audio : .video
        for track in allTracks where track.kind == siblingKind {
            if let match = track.clips.first(where: {
                $0.mediaID == clip.mediaID
                    && $0.timelineStart == clip.timelineStart
                    && $0.sourceStart == clip.sourceStart
                    && $0.duration == clip.duration
            }) {
                return match.id
            }
        }
        return nil
    }

    // MARK: - Skin smoothing

    /// Returns the skin smooth effect for the selected clip, inserting a neutral one if absent.
    var selectedClipSkinSmooth: SkinSmoothEffect {
        get {
            guard let clip = selectedClip else { return .neutral }
            if let effect = clip.effects.first(where: { if case .skinSmooth = $0 { return true }; return false }),
               case .skinSmooth(let s) = effect {
                return s
            }
            return .neutral
        }
        set {
            guard let id = selectedClipID else { return }
            performCoalescedUndoable("Adjust Skin Smooth", target: id, rebuild: .debounced) {
                for track in project.videoTracks {
                    guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                    var smooth = newValue
                    smooth.clamp()
                    if let effectIndex = track.clips[index].effects.firstIndex(where: {
                        if case .skinSmooth = $0 { return true }; return false
                    }) {
                        track.clips[index].effects[effectIndex] = .skinSmooth(smooth)
                    } else {
                        track.clips[index].effects.append(.skinSmooth(smooth))
                    }
                    RenderCache.shared.invalidate(clipID: id)
                    return
                }
            }
        }
    }

    /// Updates the skin smooth effect on the selected clip.
    func updateSelectedClipSkinSmooth(_ transform: @escaping (inout SkinSmoothEffect) -> Void) {
        guard let id = selectedClipID else { return }
        performCoalescedUndoable("Adjust Skin Smooth", target: id, rebuild: .debounced) {
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                if let effectIndex = track.clips[index].effects.firstIndex(where: {
                    if case .skinSmooth = $0 { return true }; return false
                }) {
                    if case .skinSmooth(var smooth) = track.clips[index].effects[effectIndex] {
                        transform(&smooth)
                        smooth.clamp()
                        track.clips[index].effects[effectIndex] = .skinSmooth(smooth)
                    }
                } else {
                    var smooth = SkinSmoothEffect()
                    transform(&smooth)
                    smooth.clamp()
                    track.clips[index].effects.append(.skinSmooth(smooth))
                }
                RenderCache.shared.invalidate(clipID: id)
                return
            }
        }
    }

    var selectedClipSkinSmoothStrengthAtPlayhead: Float {
        guard let time = selectedClipSourceLocalPlayheadTime else {
            return selectedClipSkinSmoothDefaultStrength
        }
        return selectedClipSkinSmooth.strength(at: time)
    }

    var selectedClipSkinSmoothDefaultStrength: Float {
        SkinSmoothEffect.clampedStrength(selectedClipSkinSmooth.strength.defaultValue)
    }

    var selectedClipSkinSmoothStrengthKeyframeAtPlayhead: Keyframe<Float>? {
        guard let time = selectedClipSourceLocalPlayheadTime else { return nil }
        return nearestSkinSmoothStrengthKeyframe(to: time)
    }

    var hasPreviousSelectedClipSkinSmoothStrengthKeyframe: Bool {
        guard let localTime = selectedClipSourceLocalPlayheadTime else { return false }
        return previousSelectedClipSkinSmoothStrengthKeyframe(before: localTime) != nil
    }

    var hasNextSelectedClipSkinSmoothStrengthKeyframe: Bool {
        guard let localTime = selectedClipSourceLocalPlayheadTime else { return false }
        return nextSelectedClipSkinSmoothStrengthKeyframe(after: localTime) != nil
    }

    func addOrUpdateSelectedClipSkinSmoothStrengthKeyframe() {
        guard let id = selectedClipID,
              let localTime = selectedClipSourceLocalPlayheadTime else {
            statusMessage = "Move the playhead over the selected clip to add a keyframe."
            return
        }

        let existingID = selectedClipSkinSmoothStrengthKeyframeAtPlayhead?.id
        let value = selectedClipSkinSmoothDefaultStrength
        performUndoable(existingID == nil ? "Add Skin Smooth Keyframe" : "Update Skin Smooth Keyframe") {
            mutateSelectedSkinSmooth(clipID: id) { smooth in
                if let existingID {
                    smooth.strength.updateKeyframe(id: existingID, time: localTime, value: value)
                } else {
                    smooth.strength.addKeyframe(at: localTime, value: value)
                }
            }
            statusMessage = "Skin-smooth keyframe set at \(TimeFormatting.timecode(localTime.seconds))."
        }
    }

    func removeSelectedClipSkinSmoothStrengthKeyframe() {
        guard let id = selectedClipID,
              let keyframe = selectedClipSkinSmoothStrengthKeyframeAtPlayhead else {
            statusMessage = "No skin-smooth keyframe at the playhead."
            return
        }

        performUndoable("Remove Skin Smooth Keyframe") {
            mutateSelectedSkinSmooth(clipID: id) { smooth in
                smooth.strength.removeKeyframe(id: keyframe.id)
            }
            statusMessage = "Removed skin-smooth keyframe."
        }
    }

    func seekToPreviousSelectedClipSkinSmoothStrengthKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipSourceLocalPlayheadTime,
              let previous = previousSelectedClipSkinSmoothStrengthKeyframe(
                before: localTime) else { return }
        // Keyframe times are clip-source-relative; map back to the output domain
        // so the seek lands on the right frame for retimed clips.
        let outputOffset = clip.outputOffset(forSourceOffset: previous.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    func seekToNextSelectedClipSkinSmoothStrengthKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipSourceLocalPlayheadTime,
              let next = nextSelectedClipSkinSmoothStrengthKeyframe(
                after: localTime) else { return }
        // Keyframe times are clip-source-relative; map back to the output domain
        // so the seek lands on the right frame for retimed clips.
        let outputOffset = clip.outputOffset(forSourceOffset: next.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    private var skinSmoothKeyframeHitToleranceSeconds: Double {
        0.5 / max(1, project.frameRate)
    }

    private func previousSelectedClipSkinSmoothStrengthKeyframe(
        before localTime: CMTime
    ) -> Keyframe<Float>? {
        let tolerance = skinSmoothKeyframeHitToleranceSeconds
        return selectedClipSkinSmooth.strength.keyframes.last {
            $0.time.seconds < localTime.seconds - tolerance
        }
    }

    private func nextSelectedClipSkinSmoothStrengthKeyframe(
        after localTime: CMTime
    ) -> Keyframe<Float>? {
        let tolerance = skinSmoothKeyframeHitToleranceSeconds
        return selectedClipSkinSmooth.strength.keyframes.first {
            $0.time.seconds > localTime.seconds + tolerance
        }
    }

    private func nearestSkinSmoothStrengthKeyframe(to time: CMTime) -> Keyframe<Float>? {
        let tolerance = skinSmoothKeyframeHitToleranceSeconds
        return selectedClipSkinSmooth.strength.keyframes
            .map { keyframe in (keyframe, abs((keyframe.time - time).seconds)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func mutateSelectedSkinSmooth(clipID: Clip.ID,
                                          _ transform: (inout SkinSmoothEffect) -> Void) {
        for track in project.videoTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == clipID }) else { continue }
            if let effectIndex = track.clips[index].effects.firstIndex(where: {
                if case .skinSmooth = $0 { return true }; return false
            }) {
                if case .skinSmooth(var smooth) = track.clips[index].effects[effectIndex] {
                    transform(&smooth)
                    smooth.clamp()
                    track.clips[index].effects[effectIndex] = .skinSmooth(smooth)
                }
            } else {
                var smooth = SkinSmoothEffect()
                transform(&smooth)
                smooth.clamp()
                track.clips[index].effects.append(.skinSmooth(smooth))
            }
            RenderCache.shared.invalidate(clipID: clipID)
            scheduleRebuild()
            return
        }
    }

    /// Removes the skin smooth effect from the selected clip.
    func resetClipSkinSmooth() {
        guard let id = selectedClipID else { return }
        performUndoable("Reset Skin Smooth") {
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                track.clips[index].effects.removeAll { if case .skinSmooth = $0 { return true }; return false }
                RenderCache.shared.invalidate(clipID: id)
                scheduleRebuild()
                return
            }
        }
    }

    var selectedClip: Clip? {
        guard let id = selectedClipID else { return nil }
        return clip(for: id)
    }

    var selectedMedia: MediaItem? {
        guard let id = selectedMediaID else { return nil }
        return project.media(for: id)
    }

    /// Finds the `Track` that contains the clip with the given ID. O(1) via index.
    func track(for clipID: Clip.ID) -> Track? {
        if let entry = clipIndex[clipID] {
            switch entry.trackKind {
            case .video:
                if entry.trackIndex < project.videoTracks.count {
                    let track = project.videoTracks[entry.trackIndex]
                    if entry.clipIndex < track.clips.count,
                       track.clips[entry.clipIndex].id == clipID {
                        return track
                    }
                }
            case .audio:
                if entry.trackIndex < project.audioTracks.count {
                    let track = project.audioTracks[entry.trackIndex]
                    if entry.clipIndex < track.clips.count,
                       track.clips[entry.clipIndex].id == clipID {
                        return track
                    }
                }
            case .layout:
                break
            }
        }
        return allTracks.first { track in track.clips.contains { $0.id == clipID } }
    }

    /// Returns the clip with the given ID. O(1) via index.
    func clip(for clipID: Clip.ID) -> Clip? {
        if let entry = clipIndex[clipID] {
            switch entry.trackKind {
            case .video:
                if entry.trackIndex < project.videoTracks.count,
                   entry.clipIndex < project.videoTracks[entry.trackIndex].clips.count {
                    let clip = project.videoTracks[entry.trackIndex].clips[entry.clipIndex]
                    if clip.id == clipID { return clip }
                }
            case .audio:
                if entry.trackIndex < project.audioTracks.count,
                   entry.clipIndex < project.audioTracks[entry.trackIndex].clips.count {
                    let clip = project.audioTracks[entry.trackIndex].clips[entry.clipIndex]
                    if clip.id == clipID { return clip }
                }
            case .layout:
                break
            }
        }
        return allTracks.lazy.flatMap(\.clips).first { $0.id == clipID }
    }

    // MARK: - Transitions

    /// The trailing clip whose transition is currently selected, if any.
    var selectedTransitionClipID: Clip.ID?

    /// The selected transition, or `nil` if none is selected (or it was removed).
    var selectedTransition: Transition? {
        guard let id = selectedTransitionClipID else { return nil }
        return clip(for: id)?.transition
    }

    /// The selected overlay clip, or `nil` if none is selected.
    var selectedOverlay: OverlayClip? {
        guard let id = selectedOverlayID else { return nil }
        return project.overlays.first(where: { $0.id == id })
    }

    /// Selects an overlay by ID, clearing other selections.
    func selectOverlay(_ id: OverlayClip.ID?) {
        selectedOverlayID = id
        selectedClipID = nil
        selectedMediaID = nil
        selectedMarkerID = nil
        selectedTransitionClipID = nil
    }

    /// The adjacent predecessor of `clipID` on the same track, if the two clips
    /// are butt-joined (a valid cut to host a transition).
    private func adjacentPredecessor(of clipID: Clip.ID) -> (track: Track, previous: Clip, clip: Clip)? {
        guard let track = track(for: clipID) else { return nil }
        let ordered = track.clips.sorted { $0.timelineStart < $1.timelineStart }
        guard let index = ordered.firstIndex(where: { $0.id == clipID }), index > 0 else { return nil }
        let previous = ordered[index - 1]
        let clip = ordered[index]
        let gap = abs((clip.timelineStart - previous.timelineEnd).seconds)
        guard gap < TransitionLayout.adjacencyTolerance else { return nil }
        return (track, previous, clip)
    }

    /// The overlap available to `clipID`'s incoming transition, matching the
    /// render-time clamp: the predecessor's head is already consumed by *its* own
    /// transition, so only its remaining tail (and this clip's length) is free.
    private func chainedAvailableOverlap(forClip clipID: Clip.ID) -> CMTime {
        guard let context = adjacentPredecessor(of: clipID) else { return .zero }
        let ordered = context.track.clips.sorted { $0.timelineStart < $1.timelineStart }
        let overlaps = TransitionLayout.orderedOverlaps(ordered)
        guard let index = ordered.firstIndex(where: { $0.id == clipID }) else { return .zero }
        // Subtract the predecessor's incoming overlap from its output duration
        // to get the available tail. This matches the render-time clamp in
        // TransitionLayout.orderedOverlaps.
        let predecessorOverlap = index > 0 ? overlaps[index - 1] : .zero
        let availableTail = CMTimeMaximum(context.previous.outputDuration - predecessorOverlap, .zero)
        return CMTimeMinimum(context.clip.outputDuration, availableTail)
    }

    /// Whether a transition can be added at the current clip selection: a video
    /// clip that follows an adjacent clip and does not already have one.
    var canAddTransitionAtSelection: Bool {
        guard let id = selectedClipID else { return false }
        return canAddTransition(toClipID: id)
    }

    /// Per-clip transition eligibility check, used by the timeline's
    /// per-clip context menu so the menu item can disable itself when the
    /// user right-clicks a clip that already has a transition or has no
    /// predecessor on the same video track.
    func canAddTransition(toClipID id: Clip.ID) -> Bool {
        guard let context = adjacentPredecessor(of: id),
              context.track.kind == .video,
              context.clip.transition == nil else { return false }
        return true
    }

    /// Adds a cross-dissolve at the given clip's incoming cut without going
    /// through the selection. The timeline's context menu uses this so a
    /// right-click on a clip can add a transition without first selecting it.
    func addTransition(toClipID id: Clip.ID) {
        selectedClipID = id
        selectedTransitionClipID = nil
        selectedOverlayID = nil
        addTransitionToSelectedClip()
    }

    /// The largest overlap available to the selected transition, accounting for
    /// chained transitions. Drives the inspector's duration ceiling so it matches
    /// what the render will actually allow.
    var selectedTransitionMaxDuration: CMTime {
        guard let id = selectedTransitionClipID else { return .zero }
        return chainedAvailableOverlap(forClip: id)
    }

    /// Adds a default cross-dissolve at the selected clip's incoming cut,
    /// clamped to the available overlap, and selects it for editing.
    func addTransitionToSelectedClip() {
        guard let id = selectedClipID,
              let context = adjacentPredecessor(of: id),
              context.track.kind == .video else {
            statusMessage = "Select a video clip that follows another to add a transition."
            return
        }
        let duration = CMTimeMinimum(Transition.defaultDuration, chainedAvailableOverlap(forClip: id))
        performUndoable("Add Transition") {
            setTransition(Transition(duration: duration), onClip: id)
            selectedClipID = nil
            selectedMediaID = nil
            selectedMarkerID = nil
            selectedOverlayID = nil
            selectedTransitionClipID = id
            statusMessage = "Added a transition."
        }
    }

    /// Mutates the selected transition. Continuous edits (duration drag) pass
    /// `coalesced: true` to coalesce the gesture into one undo step.
    func updateSelectedTransition(coalesced: Bool = false, _ body: (inout Transition) -> Void) {
        guard let id = selectedTransitionClipID else { return }
        if coalesced {
            performCoalescedUndoable("Adjust Transition", target: id, rebuild: .debounced) {
                applyToSelectedTransition(id: id, body)
            }
        } else {
            performUndoable("Change Transition") {
                applyToSelectedTransition(id: id, body)
                scheduleRebuild()
            }
        }
    }

    private func applyToSelectedTransition(id: Clip.ID, _ body: (inout Transition) -> Void) {
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }),
                  var transition = track.clips[index].transition else { continue }
            body(&transition)
            track.clips[index].transition = transition
            return
        }
    }

    /// Removes the selected transition, restoring the plain cut (R3.3).
    func removeSelectedTransition() {
        guard let id = selectedTransitionClipID else { return }
        performUndoable("Delete Transition") {
            setTransition(nil, onClip: id)
            selectedTransitionClipID = nil
            statusMessage = "Deleted the transition."
        }
    }

    private func setTransition(_ transition: Transition?, onClip id: Clip.ID) {
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            track.clips[index].transition = transition
            scheduleRebuild()
            return
        }
    }

    // MARK: - Trim & drag

    enum TrimEdge { case left, right }

    /// Trims a clip edge to the given timeline time, clamping to source bounds,
    /// a one-frame minimum length, and neighbouring clip boundaries on the same
    /// track so trims never create overlaps.
    func trimClip(id: Clip.ID, edge: TrimEdge, to time: CMTime) {
        projectEditingService.trimClip(id: id, edge: edge, to: time, model: self)
    }

    /// Moves a clip to a target track at the given timeline start. The target
    /// track must be the same kind (video↔video, audio↔audio). Overlapping clips
    /// on the target track are resolved by snapping to the nearest gap.
    func moveClip(id: Clip.ID, toTrack targetTrackID: Track.ID, start: CMTime) {
        projectEditingService.moveClip(id: id, toTrack: targetTrackID, start: start, model: self)
    }

    /// Collects all authored snap targets: playhead position(s), every clip
    /// boundary (excluding the given clip), and the timeline origin (0).
    func snapTargets(excluding clipID: Clip.ID? = nil) -> [CMTime] {
        // Beat targets are added inside ProjectEditingService.snapTargets so both
        // this wrapper and the drag-gesture resolveSnap path see them.
        projectEditingService.snapTargets(excluding: clipID, model: self)
    }

    /// Clears transitions left dangling on clips no longer adjacent to a
    /// predecessor (e.g. after a beat align moves a clip away from its neighbour).
    func sanitizeTransitions() {
        projectEditingService.sanitizeTransitions(model: self)
    }

    /// Returns the nearest snap target within threshold, or the candidate
    /// itself if nothing is close enough. When `trailingEdgeOffset` is
    /// provided, the trailing edge is also tested and the start is adjusted
    /// so the trailing edge lands on the target.
    func resolveSnap(candidate: CMTime, excluding clipID: Clip.ID? = nil,
                     trailingEdgeOffset: CMTime? = nil, threshold: Double? = nil) -> CMTime {
        projectEditingService.resolveSnap(
            candidate: candidate,
            excluding: clipID,
            trailingEdgeOffset: trailingEdgeOffset,
            threshold: threshold,
            model: self)
    }

    // MARK: - Render settings

    /// Changes the output canvas size as one undoable step.
    func setRenderSize(_ size: CGSize) {
        projectEditingService.setRenderSize(size, model: self)
    }

    /// Changes the output canvas aspect as one undoable step.
    func setProjectAspect(_ aspect: ProjectAspect) {
        projectEditingService.setProjectAspect(aspect, model: self)
    }

    /// Changes the output frame rate as one undoable step.
    func setFrameRate(_ fps: Double) {
        projectEditingService.setFrameRate(fps, model: self)
    }

    /// Changes the project's working colour space as one undoable step. Purges
    /// the title-raster cache so cached captions re-render in the new space
    /// (R1.3) and rebuilds the preview so the new buffer tagging takes effect.
    func setWorkingColourSpace(_ space: WorkingColourSpace) {
        projectEditingService.setWorkingColourSpace(space, model: self)
    }

    // MARK: - Composition / playback

    /// Rebuilds the preview composition from the current project state, keeping
    /// the playhead where it was and resuming playback if still active.
    func rebuild() async {
        rebuildClipIndex()
        await previewRebuildCoordinator.rebuild(model: self)
    }

    func replacePreviewItem(with item: AVPlayerItem?, overlaySourceRegistryID: UUID? = nil) {
        let previousRegistryID = activeOverlaySourceRegistryID
        activeOverlaySourceRegistryID = overlaySourceRegistryID
        player.replaceCurrentItem(with: item)
        hasPreviewItem = item != nil
        EffectCompositor.releaseOverlaySources(for: previousRegistryID)
    }

    func togglePlayPause() {
        guard hasPreviewItem else { return }
        if isPlaying {
            player.pause()
            if project.voiceCleanup.requiresOfflineProcessing {
                audioBus.pauseLivePreview()
            }
            isPlaying = false
        } else {
            if currentTime >= totalDuration - 0.05 {
                player.seek(to: .zero)
                if project.voiceCleanup.requiresOfflineProcessing {
                    audioBus.seekLivePreview(to: .zero) { [weak self] message in
                        self?.statusMessage = Self.failureStatusMessage(
                            summary: "Live voice cleanup unavailable",
                            detail: message,
                            recoverySuggestion: "Export to apply voice cleanup offline.")
                    }
                }
            }
            player.play()
            if project.voiceCleanup.requiresOfflineProcessing {
                audioBus.resumeLivePreview()
            }
            isPlaying = true
        }
    }

    func seek(toSeconds seconds: Double) {
        seek(toSeconds: seconds, tolerance: .zero)
    }

    /// Seek with a caller-supplied tolerance. Use a non-zero tolerance during
    /// interactive scrubbing for smooth 60 fps tracking, then call
    /// `seek(toSeconds:)` (zero tolerance) on gesture end for frame-accurate
    /// positioning.
    func seek(toSeconds seconds: Double, tolerance: CMTime) {
        let clamped = max(0, min(seconds, totalDuration))
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        if project.voiceCleanup.requiresOfflineProcessing {
            audioBus.seekLivePreview(to: time) { [weak self] message in
                self?.statusMessage = Self.failureStatusMessage(
                    summary: "Live voice cleanup unavailable",
                    detail: message,
                    recoverySuggestion: "Export to apply voice cleanup offline.")
            }
            if isPlaying {
                audioBus.resumeLivePreview()
            }
        }
    }

    // MARK: - Audio metering

    func prepareAudioMetering() {
        if project.voiceCleanup.requiresOfflineProcessing {
            rebuildDebounced(after: .milliseconds(0))
        } else {
            audioBus.prepareLive()
        }
        if let error = audioBus.lastStartError {
            statusMessage = Self.failureStatusMessage(
                summary: "Live metering unavailable",
                detail: error,
                recoverySuggestion: "Check the selected audio output in System Settings > Sound, then try again.")
        } else if audioBus.isLiveRunning {
            statusMessage = "Live metering started."
        }
    }

    func teardownAudioMetering() {
        audioBus.teardownLive()
    }

    // MARK: - Export

    /// Toolbar/menu Export shortcut. Captures a security-scoped bookmark for
    /// the chosen destination, snapshots the project, and enqueues a job with
    /// the default preset (`BuiltInExportPresets.defaultPreset`). The
    /// `RenderQueue` runner picks it up immediately and reports progress
    /// through `renderQueue.totalProgress` instead of the legacy
    /// `exportProgress` field.
    func export(to url: URL) async -> EditorCommandOutcome {
        await exportCoordinator.export(to: url, model: self)
    }
}
