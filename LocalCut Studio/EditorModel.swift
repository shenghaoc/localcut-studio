import Foundation
import AVFoundation
import CoreGraphics
import Observation

/// The single source of truth driving the editor UI: it owns the project, the
/// preview `AVPlayer`, the current selection, and the timeline view state, and it
/// rebuilds the composition whenever the arrangement changes.
@Observable
@MainActor
final class EditorModel {

    let project = Project()

    /// Runtime audio master bus (P16). Owns the live + offline `AVAudioEngine`
    /// graphs and the peak/RMS meter snapshot; persistent parameters live on
    /// `project`. Created here so the inspector can bind to a stable instance
    /// for the editor's lifetime; engine startup is deferred to Phase 36 so
    /// landing the bus does not regress the current `AVPlayer` preview path.
    let audioBus = AudioMasterBus()

    // Selection
    var selectedClipID: Clip.ID?
    var selectedMediaID: MediaItem.ID?
    /// The marker currently highlighted on the timeline ruler / inspector.
    /// `Delete` only removes a marker when this is set, so the existing
    /// clip / transition delete shortcut keeps working unchanged.
    var selectedMarkerID: TimelineMarker.ID?

    // Playback
    let player = AVPlayer()
    var isPlaying = false
    /// Playhead position in seconds.
    var currentTime: Double = 0
    var totalDuration: Double = 0

    // Timeline view state
    var pixelsPerSecond: Double = 80

    // Scopes panel (colour-management feature) — session-only UI flag, not persisted.
    var showScopes: Bool = false

    // Status / export
    var statusMessage = "Import media to begin."

    /// Serial render queue, owned for the lifetime of the editor. Loaded once
    /// during init so a queue saved by the previous session resumes cleanly.
    /// Replaces the legacy `isExporting` / `exportProgress` fields — progress
    /// now lives on `renderQueue.totalProgress` and the per-job rows.
    let renderQueue: RenderQueue

    // Skin smoothing debug
    var showSkinMask = false

    /// Session cache of imported LUT filenames keyed by their bookmark, so the
    /// inspector can show a LUT's name without resolving the security-scoped
    /// bookmark on the main actor on every render. Not persisted; a LUT from a
    /// reopened project shows a generic label until re-imported.
    @ObservationIgnored private var lutDisplayNames: [Data: String] = [:]

    // Diagnostics
    /// Drives whether the diagnostics overlay is on screen and whether the
    /// `DiagnosticsAgent`'s 1 Hz timer is sampling. Hidden by default so a
    /// long-running export doesn't pay the probe cost.
    var isDiagnosticsVisible = false {
        didSet { syncDiagnosticsLifecycle() }
    }
    let diagnostics: DiagnosticsAgent

    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    @ObservationIgnored var pendingRebuildTask: Task<Void, Never>?
    /// The in-flight preview rebuild. A new rebuild cancels the previous one so
    /// rapid edits/undo can't land an older composition on the player last.
    @ObservationIgnored var activeRebuildTask: Task<Void, Never>?

    // MARK: Document state
    /// The file backing the current project, or `nil` for an unsaved one.
    var documentURL: URL?
    /// Whether the project has unsaved changes (drives the window's edited dot).
    var isDirty = false
    /// Media references whose files couldn't be resolved on open; awaiting relink.
    var unresolvedMedia: [MediaRef] = []
    /// SHA-256 of every bundled asset as of the last successful bundle read or
    /// write. Used by the next bundle save's fast path to skip re-copying media
    /// whose source hasn't changed since the previous save.
    @ObservationIgnored var lastBundleFingerprints = FingerprintIndex()

    // MARK: Undo state
    @ObservationIgnored let undoManager = UndoManager()
    var canUndo = false
    var canRedo = false
    var undoTitle = "Undo"
    var redoTitle = "Redo"
    @ObservationIgnored var coalescedUndoBefore: ProjectState?
    @ObservationIgnored var coalescedUndoName: String?
    @ObservationIgnored var coalescedUndoTarget: AnyHashable?
    @ObservationIgnored var coalescedCommitTask: Task<Void, Never>?
    /// `isDirty` at the start of the current coalesced gesture, restored if the
    /// gesture settles with no net change (so a no-op edit doesn't prompt to save).
    @ObservationIgnored var coalescedUndoWasDirty = false

    /// Monotonically increases on every mutation; lets an async save tell whether
    /// the project changed between snapshotting its data and finishing the write.
    @ObservationIgnored var mutationRevision = 0

    /// Security-scoped resources retained for the session, stopped on teardown.
    /// Holds **per-file** bookmark-resolved URLs only — never the outer
    /// `.lcbundle` directory URL. The bundle's grant lives on
    /// `bundleAccessURL` so `reconcileAccessedURLs` (which compares this set
    /// to `project.mediaItems.map(\.url)`) can't accidentally revoke it on
    /// undo/redo (the bundle URL is never equal to any media item URL —
    /// item URLs point at files *inside* the bundle).
    @ObservationIgnored nonisolated(unsafe) var accessedURLs: Set<URL> = []

    /// Security-scoped access on the outer `.lcbundle` directory, when the
    /// current document is a bundle. Tracked separately from `accessedURLs`
    /// for the reason in that property's doc. Stopped on session teardown.
    @ObservationIgnored nonisolated(unsafe) var bundleAccessURL: URL?

    /// Bumped on every session swap (New/Open). Async import/relink capture it
    /// and bail if it changes across their awaits, so work started for one
    /// document can neither leak security-scoped access nor land clips in another.
    @ObservationIgnored var sessionGeneration = 0

    init() {
        // Initialise the render queue first — it's the one `let` without an
        // inline default, so it must be set before any other access on self.
        self.renderQueue = RenderQueue()

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
            }
        }

        // Restore any jobs persisted from the previous session and resume the
        // runner (running jobs are rewound to queued; stale bookmarks flip to
        // failed — see RenderQueue.reconcile).
        renderQueue.load()
    }

    deinit {
        pendingRebuildTask?.cancel()
        activeRebuildTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
    }

    /// Starts or stops the diagnostics agent to match the panel's visibility.
    private func syncDiagnosticsLifecycle() {
        if isDiagnosticsVisible { diagnostics.start() } else { diagnostics.stop() }
    }

    // MARK: - Import

    /// Loads the given files into the media bin, reading metadata and a poster
    /// frame for each. Security-scoped access is retained for the session.
    func importMedia(urls: [URL]) async {
        let generation = sessionGeneration
        var loaded: [MediaItem] = []
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            let item = MediaItem(url: url)
            do {
                item.duration = try await item.asset.load(.duration).sanitized

                if let v = try await item.asset.loadTracks(withMediaType: .video).first {
                    item.hasVideo = true
                    item.naturalSize = try await v.load(.naturalSize).sanitized
                    item.preferredTransform = try await v.load(.preferredTransform).sanitized
                }
                item.hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty

                // If the document was replaced (New/Open) while this file's metadata
                // loaded, the import belongs to a session that no longer exists:
                // release the just-started token and abandon, rather than leaking
                // access or appending clips onto the new document. Tokens retained
                // for earlier items were already stopped by releaseSession().
                guard sessionGeneration == generation else {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                    return
                }

                // Retain access for the session and capture a persistable bookmark
                // so the file can be re-resolved after relaunch (R1.2).
                retainAccess(url, didStart: didAccess)
                item.bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
                loaded.append(item)
            } catch {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                statusMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        guard !loaded.isEmpty else { return }
        // A teardown during a *later* file's load — where that load then threw and
        // took the catch path, bypassing the per-item guard above — can still reach
        // here with stale items. releaseSession() already stopped their tokens, so
        // discard them rather than appending onto the replacement document.
        guard sessionGeneration == generation else { return }

        // Snapshot and append synchronously (no awaits between) so a concurrent
        // edit made while metadata loaded can't be folded into the import's
        // undo step.
        let before = captureState()
        project.mediaItems.append(contentsOf: loaded)
        registerImportUndo(name: "Import Media", before: before)
        markDirty()
        statusMessage = loaded.count == 1 ? "Imported \(loaded[0].name)." : "Imported \(loaded.count) items."
        // Decode poster frames off the editor: the task retains only the MediaItem
        // (via loadThumbnail), never EditorModel, so tearing down the editor mid-
        // decode doesn't keep the whole model alive.
        for item in loaded { Task { await item.loadThumbnail() } }
    }

    // MARK: - Timeline editing

    /// Appends a media item to the end of the timeline (ripple-append) on the
    /// first video and/or audio track, depending on what the media contains.
    func addToTimeline(mediaID: MediaItem.ID) {
        guard let media = project.media(for: mediaID) else { return }
        performUndoable("Add Clip") {
            let insertAt = project.duration
            let fullRange = CMTimeRange(start: .zero, duration: media.duration)

            if media.hasVideo, let track = project.videoTracks.first {
                track.clips.append(Clip(mediaID: mediaID,
                                        sourceStart: fullRange.start,
                                        duration: fullRange.duration,
                                        timelineStart: insertAt))
            }
            if media.hasAudio, let track = project.audioTracks.first {
                track.clips.append(Clip(mediaID: mediaID,
                                        sourceStart: fullRange.start,
                                        duration: fullRange.duration,
                                        timelineStart: insertAt))
            }
            statusMessage = "Added \(media.name) to timeline."
            scheduleRebuild()
        }
    }

    /// All tracks, flattened, for lookups.
    private var allTracks: [Track] { project.videoTracks + project.audioTracks }

    func deleteSelectedClip() {
        guard let id = selectedClipID else { return }
        performUndoable("Delete Clip") {
            for track in allTracks {
                track.clips.removeAll { $0.id == id }
            }
            selectedClipID = nil
            sanitizeTransitions()
            statusMessage = "Deleted clip."
            scheduleRebuild()
        }
    }

    /// Removes a media item and its orphaned clips, then stops its security-scoped access.
    func removeMedia(itemID: MediaItem.ID) {
        guard let media = project.media(for: itemID) else { return }
        // A running render job opens its own access token from the snapshot's
        // bookmark (`RenderQueue.reconstructProject`), independent of the
        // editor's security-scoped access — so removing media live is safe
        // even mid-render. The legacy single-shot export guarded with
        // `isExporting`; the queue replaces it.
        performUndoable("Remove Media") {
            project.mediaItems.removeAll { $0.id == itemID }
            releaseAccessIfUnused(for: media.url)
            for track in allTracks {
                track.clips.removeAll { $0.mediaID == itemID }
            }
            if selectedMediaID == itemID { selectedMediaID = nil }
            if let selectedClipID, clip(for: selectedClipID) == nil {
                self.selectedClipID = nil
            }
            if let selectedTransitionClipID, clip(for: selectedTransitionClipID) == nil {
                self.selectedTransitionClipID = nil
            }
            sanitizeTransitions()
            statusMessage = "Removed \(media.name)."
            scheduleRebuild()
        }
    }

    /// Releases retained file access once no media item in the project still uses it.
    private func releaseAccessIfUnused(for url: URL) {
        guard !project.mediaItems.contains(where: { $0.url == url }) else { return }
        if accessedURLs.remove(url) != nil {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Clears any clip-owned transition whose cut no longer exists — i.e. the
    /// clip is no longer immediately adjacent to a preceding clip. Prevents a
    /// stored transition from silently re-binding to a different neighbour after
    /// a move/trim/delete changes adjacency.
    private func sanitizeTransitions() {
        for track in allTracks {
            let ordered = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            for (position, clip) in ordered.enumerated() where clip.transition != nil {
                let adjacent = position > 0 &&
                    abs((clip.timelineStart - ordered[position - 1].timelineEnd).seconds) < TransitionLayout.adjacencyTolerance
                if !adjacent, let index = track.clips.firstIndex(where: { $0.id == clip.id }) {
                    track.clips[index].transition = nil
                    if selectedTransitionClipID == clip.id { selectedTransitionClipID = nil }
                }
            }
        }
    }

    /// Splits the selected clip at the current playhead into two adjacent clips.
    func splitSelectedClipAtPlayhead() {
        guard let id = selectedClipID else { return }

        performUndoable("Split Clip") {
            for track in allTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                let clip = track.clips[index]

                // The playhead is in effective (rippled) time; convert to this clip's
                // authored time using its constant ripple shift so the split lands at
                // the frame the user sees.
                let cuts = TransitionLayout.cuts(videoTracks: project.videoTracks)
                let placements = TransitionLayout.placements(for: track.clips, cuts: cuts)
                let shift = placements.first(where: { $0.id == id })
                    .map { clip.timelineStart - $0.effectiveStart } ?? .zero
                let playhead = CMTime(seconds: currentTime, preferredTimescale: 600) + shift

                guard playhead > clip.timelineStart, playhead < clip.timelineEnd else { return }

                let offset = playhead - clip.timelineStart
                var left = clip
                left.duration = offset

                // Carry the authored envelope to the right half so a split
                // doesn't silently drop volume automation. The render-time
                // fade clamp already trims fades that no longer fit either
                // side's duration.
                let right = Clip(mediaID: clip.mediaID,
                                 sourceStart: clip.sourceStart + offset,
                                 duration: clip.duration - offset,
                                 timelineStart: playhead,
                                 opacity: clip.opacity,
                                 effects: clip.effects,
                                 volumeEnvelope: clip.volumeEnvelope)

                track.clips.replaceSubrange(index...index, with: [left, right])
                selectedClipID = left.id
                statusMessage = "Split clip."
                scheduleRebuild()
                return
            }
        }
    }

    /// Mutates the selected clip via the supplied closure and schedules a
    /// debounced rebuild, coalescing a continuous gesture (opacity/colour drag)
    /// into a single undo step labelled `actionName`.
    func updateSelectedClipCoalesced(_ actionName: String = "Adjust Clip",
                                     _ transform: @escaping (inout Clip) -> Void) {
        guard let id = selectedClipID else { return }
        performCoalescedUndoable(actionName, target: id, rebuild: .debounced) {
            for track in allTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                // Snapshot the pre-transform effects so we only drop cached
                // frames when `effects` actually changed — opacity drags
                // shouldn't invalidate, even though they flow through here.
                let effectsBefore = track.clips[index].effects
                transform(&track.clips[index])
                if track.clips[index].effects != effectsBefore {
                    RenderCache.shared.invalidate(clipID: id)
                }
                return
            }
        }
    }

    func rebuildDebounced(after delay: Duration = .milliseconds(200)) {
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            scheduleRebuild()
        }
    }

    /// Starts a preview rebuild, cancelling any rebuild already in flight so the
    /// most recent project state is the one that reaches the player.
    func scheduleRebuild() {
        activeRebuildTask?.cancel()
        activeRebuildTask = Task { [weak self] in await self?.rebuild() }
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
                    case .skinSmooth: false
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
            statusMessage = "Could not access \(url.lastPathComponent)."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            statusMessage = "Could not store access to \(url.lastPathComponent)."
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

    private func pruneLUTDisplayNames() {
        let activeBookmarks = Set(allTracks.flatMap(\.clips).flatMap { clip in
            clip.effects.compactMap { effect -> Data? in
                guard case .lut(let bookmark) = effect else { return nil }
                return bookmark
            }
        })
        lutDisplayNames = lutDisplayNames.filter { activeBookmarks.contains($0.key) }
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
                for track in allTracks {
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
            for track in allTracks {
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

    /// Clip-local playhead time used by the skin-smooth compositor. Returns
    /// nil when the effective playhead is outside the selected clip's authored
    /// range, because authoring a clip-local keyframe there would be ambiguous.
    var selectedClipSkinSmoothLocalPlayheadTime: CMTime? {
        guard let clip = selectedClip else { return nil }
        let playhead = CMTime(seconds: currentTime, preferredTimescale: 600)
        guard playhead >= clip.timelineStart, playhead <= clip.timelineEnd else { return nil }
        return CMTimeMaximum(.zero, CMTimeMinimum(playhead - clip.timelineStart, clip.duration))
    }

    var selectedClipSkinSmoothStrengthAtPlayhead: Float {
        guard let time = selectedClipSkinSmoothLocalPlayheadTime else {
            return selectedClipSkinSmooth.strength.defaultValue
        }
        return selectedClipSkinSmooth.strength.value(at: time)
    }

    var selectedClipSkinSmoothStrengthKeyframeAtPlayhead: Keyframe<Float>? {
        guard let time = selectedClipSkinSmoothLocalPlayheadTime else { return nil }
        return nearestSkinSmoothStrengthKeyframe(to: time)
    }

    func addOrUpdateSelectedClipSkinSmoothStrengthKeyframe() {
        guard let id = selectedClipID,
              let localTime = selectedClipSkinSmoothLocalPlayheadTime else {
            statusMessage = "Move the playhead over the selected clip to add a keyframe."
            return
        }

        let existingID = selectedClipSkinSmoothStrengthKeyframeAtPlayhead?.id
        let value = selectedClipSkinSmooth.strength.defaultValue
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
              let localTime = selectedClipSkinSmoothLocalPlayheadTime else { return }
        let tolerance = skinSmoothKeyframeHitToleranceSeconds
        guard let previous = selectedClipSkinSmooth.strength.keyframes.last(where: {
            $0.time.seconds < localTime.seconds - tolerance
        }) else { return }
        seek(toSeconds: (clip.timelineStart + previous.time).seconds)
    }

    func seekToNextSelectedClipSkinSmoothStrengthKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipSkinSmoothLocalPlayheadTime else { return }
        let tolerance = skinSmoothKeyframeHitToleranceSeconds
        guard let next = selectedClipSkinSmooth.strength.keyframes.first(where: {
            $0.time.seconds > localTime.seconds + tolerance
        }) else { return }
        seek(toSeconds: (clip.timelineStart + next.time).seconds)
    }

    private var skinSmoothKeyframeHitToleranceSeconds: Double {
        0.5 / max(1, project.frameRate)
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
        for track in allTracks {
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
            for track in allTracks {
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
        for track in allTracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    var selectedMedia: MediaItem? {
        guard let id = selectedMediaID else { return nil }
        return project.media(for: id)
    }

    /// Finds the `Track` that contains the clip with the given ID.
    func track(for clipID: Clip.ID) -> Track? {
        allTracks.first { $0.clips.contains(where: { $0.id == clipID }) }
    }

    func clip(for clipID: Clip.ID) -> Clip? {
        for track in allTracks {
            if let clip = track.clips.first(where: { $0.id == clipID }) { return clip }
        }
        return nil
    }

    // MARK: - Transitions

    /// The trailing clip whose transition is currently selected, if any.
    var selectedTransitionClipID: Clip.ID?

    /// The selected transition, or `nil` if none is selected (or it was removed).
    var selectedTransition: Transition? {
        guard let id = selectedTransitionClipID else { return nil }
        return clip(for: id)?.transition
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
        let availableTail = CMTimeMaximum(context.previous.duration - overlaps[index - 1], .zero)
        return CMTimeMinimum(context.clip.duration, availableTail)
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
            selectedTransitionClipID = id
            statusMessage = "Added transition."
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
        performUndoable("Remove Transition") {
            setTransition(nil, onClip: id)
            selectedTransitionClipID = nil
            statusMessage = "Removed transition."
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

    /// One render frame at the project's frame rate — the shortest a clip can be.
    private var minClipDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, project.frameRate)))
    }

    /// Trims a clip edge to the given timeline time, clamping to source bounds,
    /// a one-frame minimum length, and neighbouring clip boundaries on the same
    /// track so trims never create overlaps.
    func trimClip(id: Clip.ID, edge: TrimEdge, to time: CMTime) {
        performCoalescedUndoable("Trim Clip", target: id, rebuild: .immediate) {
            for track in allTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                var clip = track.clips[index]
                guard let media = project.media(for: clip.mediaID) else { return }
                let sourceDuration = media.duration
                let minDur = minClipDuration

                let sorted = track.clips.sorted { $0.timelineStart < $1.timelineStart }
                guard let sortedIndex = sorted.firstIndex(where: { $0.id == id }) else { return }
                let prevClip = sortedIndex > 0 ? sorted[sortedIndex - 1] : nil
                let nextClip = sortedIndex < sorted.count - 1 ? sorted[sortedIndex + 1] : nil

                switch edge {
                case .left:
                    let originalEnd = clip.timelineEnd
                    var newTimelineStart = max(time, .zero)
                    let minTimelineStart = clip.timelineStart - clip.sourceStart
                    newTimelineStart = max(newTimelineStart, minTimelineStart)
                    let maxTimelineStart = originalEnd - minDur
                    newTimelineStart = min(newTimelineStart, maxTimelineStart)
                    if let prev = prevClip {
                        newTimelineStart = max(newTimelineStart, prev.timelineEnd)
                    }

                    let delta = newTimelineStart - clip.timelineStart
                    clip.sourceStart = clip.sourceStart + delta
                    clip.timelineStart = newTimelineStart
                    clip.duration = originalEnd - newTimelineStart

                case .right:
                    let maxSourceRemaining = sourceDuration - clip.sourceStart
                    var newDuration = time - clip.timelineStart
                    newDuration = max(newDuration, minDur)
                    newDuration = min(newDuration, maxSourceRemaining)
                    if let next = nextClip {
                        let maxDuration = next.timelineStart - clip.timelineStart
                        newDuration = min(newDuration, maxDuration)
                    }
                    clip.duration = newDuration
                }

                track.clips[index] = clip
                sanitizeTransitions()
                return
            }
        }
    }

    /// Moves a clip to a target track at the given timeline start. The target
    /// track must be the same kind (video↔video, audio↔audio). Overlapping clips
    /// on the target track are resolved by snapping to the nearest gap.
    func moveClip(id: Clip.ID, toTrack targetTrackID: Track.ID, start: CMTime) {
        var sourceTrack: Track?
        var sourceIndex: Int?
        for track in allTracks {
            if let idx = track.clips.firstIndex(where: { $0.id == id }) {
                sourceTrack = track
                sourceIndex = idx
                break
            }
        }
        guard let sourceTrack, let sourceIndex else { return }
        guard let targetTrack = allTracks.first(where: { $0.id == targetTrackID }) else { return }
        guard sourceTrack.kind == targetTrack.kind else { return }

        performCoalescedUndoable("Move Clip", target: id, rebuild: .immediate) {
            var clip = sourceTrack.clips[sourceIndex]
            // Moving a clip destroys its incoming-transition cut; drop it so the
            // transition can't silently re-bind to a new neighbour at the drop site.
            if clip.transition != nil {
                clip.transition = nil
                if selectedTransitionClipID == id { selectedTransitionClipID = nil }
            }
            let newStart = max(start, .zero)
            clip.timelineStart = newStart

            // Remove from source before resolving overlaps on target.
            sourceTrack.clips.remove(at: sourceIndex)

            // Resolve overlaps: find a non-overlapping position on the target track.
            clip.timelineStart = resolveOverlap(clip: clip, on: targetTrack)
            targetTrack.clips.append(clip)
            targetTrack.clips.sort { $0.timelineStart < $1.timelineStart }

            sanitizeTransitions()
        }
    }

    /// Finds the nearest non-overlapping position for a clip on a track.
    /// Prefers the requested position; shifts to the nearest gap if blocked.
    private func resolveOverlap(clip: Clip, on track: Track) -> CMTime {
        let requested = clip.timelineStart
        let duration = clip.duration
        let others = track.clips.sorted { $0.timelineStart < $1.timelineStart }

        let requestedEnd = requested + duration
        let hasOverlap = others.contains { other in
            requested < other.timelineEnd && requestedEnd > other.timelineStart
        }
        if !hasOverlap { return requested }

        // Candidate positions: timeline origin, just after each clip, and
        // just before each clip (shifted back by duration) to cover gaps
        // that end at a clip's start.
        var candidates: [CMTime] = [.zero]
        for other in others {
            candidates.append(other.timelineEnd)
            let beforeClip = other.timelineStart - duration
            if beforeClip >= .zero {
                candidates.append(beforeClip)
            }
        }

        var bestStart = requested
        var bestDistance = Double.infinity
        for candidate in candidates {
            let candidateEnd = candidate + duration
            let wouldOverlap = others.contains { other in
                candidate < other.timelineEnd && candidateEnd > other.timelineStart
            }
            if !wouldOverlap {
                let distance = abs((candidate - requested).seconds)
                if distance < bestDistance {
                    bestDistance = distance
                    bestStart = candidate
                }
            }
        }
        return bestStart
    }

    /// Collects all authored snap targets: playhead position(s), every clip
    /// boundary (excluding the given clip), and the timeline origin (0).
    func snapTargets(excluding clipID: Clip.ID? = nil) -> [CMTime] {
        var targets: [CMTime] = [.zero]
        let effectivePlayhead = CMTime(seconds: currentTime, preferredTimescale: 600)
        let cuts = TransitionLayout.cuts(videoTracks: project.videoTracks)
        targets.append(contentsOf: TransitionLayout.authoredTimes(forEffective: effectivePlayhead, cuts: cuts))
        for track in allTracks {
            for clip in track.clips where clip.id != clipID {
                targets.append(clip.timelineStart)
                targets.append(clip.timelineEnd)
            }
        }
        return targets
    }

    /// Returns the nearest snap target within threshold, or the candidate
    /// itself if nothing is close enough. When `trailingEdgeOffset` is
    /// provided, the trailing edge is also tested and the start is adjusted
    /// so the trailing edge lands on the target.
    func resolveSnap(candidate: CMTime, excluding clipID: Clip.ID? = nil,
                     trailingEdgeOffset: CMTime? = nil, threshold: Double? = nil) -> CMTime {
        let thresholdSeconds = threshold ?? (8.0 / pixelsPerSecond)
        let targets = snapTargets(excluding: clipID)

        var nearest = candidate
        var minDist = Double.infinity

        for target in targets {
            let dist = abs((candidate - target).seconds)
            if dist < thresholdSeconds, dist < minDist {
                minDist = dist
                nearest = target
            }
        }

        if let offset = trailingEdgeOffset {
            let trailing = candidate + offset
            for target in targets {
                let dist = abs((trailing - target).seconds)
                if dist < thresholdSeconds, dist < minDist {
                    minDist = dist
                    nearest = target - offset
                }
            }
        }

        return nearest
    }

    // MARK: - Render settings

    /// Changes the output canvas size as one undoable step.
    func setRenderSize(_ size: CGSize) {
        guard size != project.renderSize else { return }
        performUndoable("Change Resolution") {
            project.renderSize = size
            RenderCache.shared.invalidate(notMatchingRenderSize: size)
            // Caption rasters are keyed on render size, so the old-resolution
            // bitmaps are now dead weight; drop them instead of waiting for LRU
            // eviction (feature-title-raster R2.3 / T1.4).
            EffectCompositor.purgeCaptionRasterCache()
            scheduleRebuild()
        }
    }

    /// Changes the output frame rate as one undoable step.
    func setFrameRate(_ fps: Double) {
        guard fps != project.frameRate else { return }
        performUndoable("Change Frame Rate") {
            project.frameRate = fps
            scheduleRebuild()
        }
    }

    /// Changes the project's working colour space as one undoable step. Purges
    /// the title-raster cache so cached captions re-render in the new space
    /// (R1.3) and rebuilds the preview so the new buffer tagging takes effect.
    func setWorkingColourSpace(_ space: WorkingColourSpace) {
        guard space != project.workingColourSpace else { return }
        performUndoable("Change Working Space") {
            project.workingColourSpace = space
            EffectCompositor.purgeCaptionRasterCache()
            scheduleRebuild()
        }
    }

    // MARK: - Composition / playback

    /// Rebuilds the preview composition from the current project state, keeping
    /// the playhead where it was and resuming playback if still active.
    func rebuild() async {
        let resumeAt = currentTime
        do {
            let result = try await CompositionBuilder.build(project: project, showSkinMask: showSkinMask)
            // A newer rebuild superseded this one; don't clobber the player.
            guard !Task.isCancelled else { return }
            guard let built = result else {
                player.replaceCurrentItem(with: nil)
                totalDuration = 0
                // No preview left to play; clear the flag so a later rebuild that
                // re-creates an item (undo, add clip) doesn't silently auto-resume.
                isPlaying = false
                DiagnosticsBridge.shared.setDecoderCount(0)
                // No compositor will run until the next non-empty rebuild, so
                // wipe the render-time ring too — otherwise GPU/last/p95 would
                // keep reporting the previous composition's numbers indefinitely
                // (Codex P2).
                DiagnosticsBridge.shared.clearRenderSamples()
                return
            }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            player.replaceCurrentItem(with: item)
            totalDuration = built.duration
            // The active VideoToolbox decoder count tracks one-to-one with the
            // composition's video tracks (each is fed from a distinct source).
            DiagnosticsBridge.shared.setDecoderCount(
                built.composition.tracks(withMediaType: .video).count)
            await player.seek(to: CMTime(seconds: min(resumeAt, built.duration), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            // Check the live isPlaying rather than a captured flag so a user's
            // pause during the async build is not overridden.
            if isPlaying {
                player.play()
            }
        } catch {
            statusMessage = "Preview build failed: \(error.localizedDescription)"
        }
    }

    func togglePlayPause() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= totalDuration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(toSeconds seconds: Double) {
        let clamped = max(0, min(seconds, totalDuration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Export

    /// Toolbar/menu Export shortcut. Captures a security-scoped bookmark for
    /// the chosen destination, snapshots the project, and enqueues a job with
    /// the default preset (`BuiltInExportPresets.defaultPreset`). The
    /// `RenderQueue` runner picks it up immediately and reports progress
    /// through `renderQueue.totalProgress` instead of the legacy
    /// `exportProgress` field.
    func export(to url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else {
            statusMessage = "Could not access \(url.lastPathComponent)."
            return
        }
        renderQueue.enqueueWithDefaultPreset(outputURL: url, project: project, bookmark: bookmark)
        statusMessage = "Queued \(url.lastPathComponent) with \(BuiltInExportPresets.defaultPreset.name)."
    }
}
