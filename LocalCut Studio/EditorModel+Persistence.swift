import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import LocalCutCore

// MARK: - Undo snapshot

/// A lightweight, in-memory snapshot of the editable arrangement. Undo/redo swap
/// whole snapshots rather than threading inverse operations through every edit,
/// so one user action maps to exactly one undo step even when many helpers run.
struct ProjectState: Equatable {
    struct TrackClips: Equatable {
        let trackID: UUID
        var name: String
        var isMuted: Bool
        var clips: [Clip]
    }

    struct CaptionTrackSnapshot: Equatable {
        let trackID: UUID
        var name: String
        var isMuted: Bool
        var defaultStyle: CaptionStyle
        var lines: [CaptionLine]
    }

    var name: String
    var media: [MediaItem]
    var unresolvedMedia: [MediaRef]
    var aspect: ProjectAspect
    var renderSize: CGSize
    var frameRate: Double
    var workingColourSpace: WorkingColourSpace
    var coverFrame: CoverFrameDoc?
    var videoTracks: [TrackClips]
    var audioTracks: [TrackClips]
    var captionTracks: [CaptionTrackSnapshot]
    var markers: [TimelineMarker]
    /// Session-only LUT filename cache, keyed by bookmark, so undo/redo of LUT
    /// replace/remove keeps the inspector label aligned with the restored effect
    /// chain without resolving security-scoped bookmarks on the main actor.
    var lutDisplayNames: [Data: String]
    /// Master-bus gain (linear, 0…2). Per-clip volume envelopes ride along
    /// inside `clips`; only bus-level parameters live here directly.
    var masterGain: Float
    /// Per-audio-track pan + gain on the bus.
    var trackInputs: [TrackInput]
    /// Phase 36 bus insert settings.
    var voiceCleanup: VoiceCleanupSettings
    /// Animated overlay clips.
    var overlays: [OverlayClip]
    /// Overlay source bookmarks keyed by overlay ID.
    var overlayBookmarks: [UUID: Data]
    /// Overlay bundle-relative paths keyed by overlay ID.
    var overlayBundlePaths: [UUID: String]
    /// Phase 43 callout clips.
    var callouts: [CalloutClip]
    var selectedClipID: Clip.ID?
    var selectedTransitionClipID: Clip.ID?
    var selectedMarkerID: TimelineMarker.ID?
    var selectedOverlayID: OverlayClip.ID?

    static func == (lhs: ProjectState, rhs: ProjectState) -> Bool {
        lhs.name == rhs.name
            && lhs.media.map(\.id) == rhs.media.map(\.id)
            && lhs.unresolvedMedia == rhs.unresolvedMedia
            && lhs.aspect == rhs.aspect
            && lhs.renderSize == rhs.renderSize
            && lhs.frameRate == rhs.frameRate
            && lhs.workingColourSpace == rhs.workingColourSpace
            && lhs.coverFrame == rhs.coverFrame
            && lhs.videoTracks == rhs.videoTracks
            && lhs.audioTracks == rhs.audioTracks
            && lhs.captionTracks == rhs.captionTracks
            && lhs.markers == rhs.markers
            && lhs.lutDisplayNames == rhs.lutDisplayNames
            && lhs.masterGain == rhs.masterGain
            && lhs.trackInputs == rhs.trackInputs
            && lhs.voiceCleanup == rhs.voiceCleanup
            && lhs.overlays == rhs.overlays
            && lhs.overlayBookmarks == rhs.overlayBookmarks
            && lhs.overlayBundlePaths == rhs.overlayBundlePaths
            && lhs.callouts == rhs.callouts
            && lhs.selectedClipID == rhs.selectedClipID
            && lhs.selectedTransitionClipID == rhs.selectedTransitionClipID
            && lhs.selectedMarkerID == rhs.selectedMarkerID
            && lhs.selectedOverlayID == rhs.selectedOverlayID
    }
}

struct RecordingUndoState: Equatable {
    var lastRecordingSlots: [RecordingSlot]
    var hasLastRecordingTake: Bool
    var lastRecordingPiPPreset: PiPPreset?
}

// MARK: - Undo / redo

extension EditorModel {

    /// How the preview should refresh after an undoable mutation. `.skip` is
    /// for edits that don't touch the composition (e.g. marker rename) so a
    /// burst of keystrokes doesn't churn `AVMutableComposition` for no reason.
    enum RebuildMode { case immediate, debounced, skip }

    /// Captures the current arrangement for undo.
    func captureState() -> ProjectState {
        ProjectState(
            name: project.name,
            media: project.mediaItems,
            unresolvedMedia: unresolvedMedia,
            aspect: project.aspect,
            renderSize: project.renderSize,
            frameRate: project.frameRate,
            workingColourSpace: project.workingColourSpace,
            coverFrame: project.coverFrame,
            videoTracks: project.videoTracks.map {
                ProjectState.TrackClips(trackID: $0.id, name: $0.name, isMuted: $0.isMuted, clips: $0.clips)
            },
            audioTracks: project.audioTracks.map {
                ProjectState.TrackClips(trackID: $0.id, name: $0.name, isMuted: $0.isMuted, clips: $0.clips)
            },
            captionTracks: project.captionTracks.map {
                ProjectState.CaptionTrackSnapshot(
                    trackID: $0.id, name: $0.name, isMuted: $0.isMuted,
                    defaultStyle: $0.defaultStyle, lines: $0.lines)
            },
            markers: project.markers,
            lutDisplayNames: lutDisplayNames,
            masterGain: project.masterGain,
            trackInputs: project.trackInputs,
            voiceCleanup: project.voiceCleanup,
            overlays: project.overlays,
            overlayBookmarks: project.overlayBookmarks,
            overlayBundlePaths: project.overlayBundlePaths,
            callouts: project.callouts,
            selectedClipID: selectedClipID,
            selectedTransitionClipID: selectedTransitionClipID,
            selectedMarkerID: selectedMarkerID,
            selectedOverlayID: selectedOverlayID)
    }

    /// Restores a previously captured arrangement. Track identities are stable
    /// within a session, so clips are matched back onto their tracks by ID.
    func applyState(_ state: ProjectState) {
        project.name = state.name
        project.mediaItems = state.media
        unresolvedMedia = state.unresolvedMedia
        project.aspect = state.aspect
        let renderSizeChanged = project.renderSize != state.renderSize
        project.renderSize = state.renderSize
        project.frameRate = state.frameRate
        let colourSpaceChanged = project.workingColourSpace != state.workingColourSpace
        project.workingColourSpace = state.workingColourSpace
        if renderSizeChanged || colourSpaceChanged {
            // Caption rasters are keyed on render size + working colour space, so
            // an undo/redo across a Change Resolution or Change Working Space step
            // must drop the now-stale entries — applyState bypasses the setters
            // that would otherwise purge.
            EffectCompositor.purgeCaptionRasterCache()
            if renderSizeChanged {
                RenderCache.shared.invalidate(notMatchingRenderSize: state.renderSize)
            }
        }
        project.coverFrame = state.coverFrame
        project.videoTracks = restoredTracks(from: state.videoTracks, existing: project.videoTracks, kind: .video)
        project.audioTracks = restoredTracks(from: state.audioTracks, existing: project.audioTracks, kind: .audio)
        // Caption tracks: restore existing-by-id, drop tracks not in the snapshot,
        // and append any from the snapshot that the current project doesn't yet have
        // (an undo that brings back a deleted track). `uniquingKeysWith` rather
        // than `uniqueKeysWithValues` so a corrupted document with duplicate
        // track ids degrades to a missed restore instead of a process crash.
        var existing: [UUID: CaptionTrack] = Dictionary(
            project.captionTracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var restored: [CaptionTrack] = []
        for snapshot in state.captionTracks {
            if let track = existing.removeValue(forKey: snapshot.trackID) {
                track.name = snapshot.name
                track.isMuted = snapshot.isMuted
                track.defaultStyle = snapshot.defaultStyle
                track.replaceLines(snapshot.lines)
                restored.append(track)
            } else {
                // A previously-deleted track returns with its original UUID, so
                // any redoable command captured against that identity still
                // resolves the track after undo brings it back.
                let track = CaptionTrack(id: snapshot.trackID,
                                         name: snapshot.name,
                                         lines: snapshot.lines)
                track.isMuted = snapshot.isMuted
                track.defaultStyle = snapshot.defaultStyle
                restored.append(track)
            }
        }
        project.captionTracks = restored
        // Markers are value types and the entire list is small; restore by
        // assignment. The sort invariant is preserved because every mutation
        // path on `EditorModel` writes a sorted list into the snapshot.
        project.markers = state.markers
        project.masterGain = state.masterGain
        project.trackInputs = state.trackInputs
        project.voiceCleanup = state.voiceCleanup
        project.overlays = state.overlays
        project.overlayBookmarks = state.overlayBookmarks
        project.overlayBundlePaths = state.overlayBundlePaths
        project.callouts = state.callouts
        selectedClipID = state.selectedClipID
        selectedTransitionClipID = state.selectedTransitionClipID
        selectedMarkerID = state.selectedMarkerID
        selectedOverlayID = state.selectedOverlayID
        restoreLUTDisplayNames(state.lutDisplayNames)
        reconcileAccessedURLs()
    }

    private func restoredTracks(from snapshots: [ProjectState.TrackClips],
                                existing tracks: [Track],
                                kind: TrackKind) -> [Track] {
        var existing = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshots.map { snapshot in
            let track = existing.removeValue(forKey: snapshot.trackID)
                ?? Track(id: snapshot.trackID, name: snapshot.name, kind: kind)
            track.name = snapshot.name
            track.isMuted = snapshot.isMuted
            track.clips = snapshot.clips
            return track
        }
    }

    /// Keeps retained security-scoped access aligned with the restored media set:
    /// releases files an undo dropped, and re-acquires files a redo brought back
    /// (the restored items hold the same security-scoped URLs, which support
    /// repeated start/stop), so undo neither leaks tokens nor breaks redo.
    private func reconcileAccessedURLs() {
        var active = Set(project.mediaItems.map(\.url))
        for overlay in project.overlays {
            guard let url = resolveOverlayURL(for: overlay) else { continue }
            active.insert(url)
        }
        for url in accessedURLs.subtracting(active) {
            url.stopAccessingSecurityScopedResource()
            accessedURLs.remove(url)
        }
        for url in active.subtracting(accessedURLs) where url.startAccessingSecurityScopedResource() {
            accessedURLs.insert(url)
        }
    }

    /// Performs a discrete, immediately-committed mutation as one undo step.
    func performUndoable(_ name: String, mutate: () -> Void) {
        invalidateLoudnessMeasurement()
        commitCoalescedUndo()
        let before = captureState()
        mutate()
        let after = captureState()
        guard before != after else { return }
        registerUndo(name: name, before: before, after: after)
        markDirty()
    }

    /// Registers undo for an asynchronous mutation whose `before` snapshot was
    /// captured at the start (e.g. media import, which appends incrementally).
    @discardableResult
    func registerImportUndo(name: String, before: ProjectState) -> Bool {
        let after = captureState()
        guard before != after else { return false }
        registerUndo(name: name, before: before, after: after)
        return true
    }

    func captureRecordingUndoState() -> RecordingUndoState {
        RecordingUndoState(
            lastRecordingSlots: lastRecordingSlots,
            hasLastRecordingTake: hasLastRecordingTake,
            lastRecordingPiPPreset: lastRecordingPiPPreset)
    }

    func applyRecordingUndoState(_ state: RecordingUndoState) {
        lastRecordingSlots = state.lastRecordingSlots
        hasLastRecordingTake = state.hasLastRecordingTake
        lastRecordingPiPPreset = state.lastRecordingPiPPreset
    }

    @discardableResult
    func registerRecordingImportUndo(name: String,
                                     before: ProjectState,
                                     beforeRecording: RecordingUndoState) -> Bool {
        let after = captureState()
        let afterRecording = captureRecordingUndoState()
        guard before != after || beforeRecording != afterRecording else { return false }
        registerUndo(
            name: name,
            before: before,
            after: after,
            beforeRecording: beforeRecording,
            afterRecording: afterRecording)
        return true
    }

    /// Performs one step of a continuous gesture (slider drag, edge trim, clip
    /// move). The `before` snapshot is captured once at the start of the gesture
    /// and a single undo step is committed shortly after the gesture settles.
    /// A change of `name` or `target` ends the previous gesture first, so two
    /// adjacent gestures never fold into one undo step.
    func performCoalescedUndoable(_ name: String, target: AnyHashable?,
                                  rebuild mode: RebuildMode, mutate: () -> Void) {
        invalidateLoudnessMeasurement()
        if coalescedUndoBefore != nil,
           coalescedUndoName != name || coalescedUndoTarget != target {
            commitCoalescedUndo()
        }
        if coalescedUndoBefore == nil {
            coalescedUndoBefore = captureState()
            coalescedUndoName = name
            coalescedUndoTarget = target
            coalescedUndoWasDirty = isDirty
        }
        mutate()
        markDirty()
        switch mode {
        case .immediate: scheduleRebuild()
        case .debounced: rebuildDebounced()
        case .skip: break
        }
        scheduleCoalescedCommit()
    }

    private func scheduleCoalescedCommit() {
        coalescedCommitTask?.cancel()
        coalescedCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.commitCoalescedUndo()
        }
    }

    /// Finalises any in-flight coalesced gesture into a single undo step.
    func commitCoalescedUndo() {
        coalescedCommitTask?.cancel()
        coalescedCommitTask = nil
        guard let before = coalescedUndoBefore, let name = coalescedUndoName else { return }
        coalescedUndoBefore = nil
        coalescedUndoName = nil
        coalescedUndoTarget = nil
        let after = captureState()
        guard before != after else {
            // The gesture settled with no net change (e.g. a trim clamped against a
            // bound, or a value dragged back to its start); undo the speculative
            // per-tick dirtying so a no-op edit doesn't show the edited dot or
            // trigger a save prompt.
            isDirty = coalescedUndoWasDirty
            return
        }
        registerUndo(name: name, before: before, after: after)
    }

    /// Registers a reversible swap between two snapshots, re-registering its
    /// inverse on invocation so redo works (the standard recursive pattern).
    private func registerUndo(name: String,
                              before: ProjectState,
                              after: ProjectState,
                              beforeRecording: RecordingUndoState? = nil,
                              afterRecording: RecordingUndoState? = nil) {
        // `groupsByEvent` is disabled (see init), so each top-level action gets
        // its own explicit group — one user action = one undo step regardless of
        // run-loop timing. While undoing/redoing, UndoManager already manages the
        // group that collects the inverse registration, so we don't open one.
        let opensGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.applyState(before)
                if let beforeRecording {
                    model.applyRecordingUndoState(beforeRecording)
                }
                model.markDirty()
                model.registerUndo(
                    name: name,
                    before: after,
                    after: before,
                    beforeRecording: afterRecording,
                    afterRecording: beforeRecording)
                model.scheduleRebuild()
                model.refreshUndoFlags()
            }
        }
        undoManager.setActionName(name)
        if opensGroup { undoManager.endUndoGrouping() }
        refreshUndoFlags()
    }

    /// Mirrors `UndoManager` availability/labels into observable state so the
    /// Edit-menu items update (UndoManager itself is not observable).
    func refreshUndoFlags() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
        undoTitle = undoManager.undoMenuItemTitle
        redoTitle = undoManager.redoMenuItemTitle
    }

    func undo() {
        commitCoalescedUndo()
        guard undoManager.canUndo else { return }
        undoManager.undo()
        refreshUndoFlags()
    }

    func redo() {
        commitCoalescedUndo()
        guard undoManager.canRedo else { return }
        undoManager.redo()
        refreshUndoFlags()
    }

    func markDirty() {
        isDirty = true
        mutationRevision &+= 1
    }
}

// MARK: - Document lifecycle

extension EditorModel {
    /// Replaces the current project with an empty one (File ▸ New).
    func newDocument() {
        invalidateLoudnessMeasurement()
        documentController.newDocument(model: self)
    }

    /// Stops every retained security-scoped resource and clears session state.
    func releaseSession() {
        documentController.releaseSession(model: self)
    }

    /// Adopts ownership of a successful `startAccessingSecurityScopedResource()`
    /// on `bundleURL` for the current document session.
    func adoptBundleAccess(_ bundleURL: URL, didStart: Bool) {
        documentController.adoptBundleAccess(bundleURL, didStart: didStart, model: self)
    }

    /// Reads and opens either a `.lcstudio` document or a `.lcbundle` package.
    func open(url: URL) async {
        await documentController.open(url: url, model: self)
    }

    /// Rebuilds the runtime project from a decoded document, resolving media bookmarks.
    func load(document: ProjectDocument,
              from url: URL?,
              bundleURL: URL? = nil,
              bundleAccessDidStart: Bool = false,
              bundleFingerprints: FingerprintIndex = FingerprintIndex(),
              externallyEditedAssets: [String] = []) async {
        invalidateLoudnessMeasurement()
        await documentController.load(document: document,
                                      from: url,
                                      bundleURL: bundleURL,
                                      bundleAccessDidStart: bundleAccessDidStart,
                                      bundleFingerprints: bundleFingerprints,
                                      externallyEditedAssets: externallyEditedAssets,
                                      model: self)
    }

    /// Saves to the current document URL, or does nothing if none is set yet.
    func save() async {
        await documentController.save(model: self)
    }

    /// Saves to a new location and adopts it as the document URL.
    func saveAs(url: URL) async {
        await documentController.saveAs(url: url, model: self)
    }

    /// Synchronous save used by tests and non-interactive callers. Window close
    /// uses the async save path so bundle cover generation can complete.
    func writeSynchronously(to url: URL) -> Bool {
        documentController.writeSynchronously(to: url, model: self)
    }

    /// Builds the document to persist, including unresolved media refs.
    func makeDocumentForSave(forBundle: Bool = false) -> ProjectDocument {
        documentController.makeDocumentForSave(forBundle: forBundle, model: self)
    }

    /// Prompts the user to locate the first unresolved media file and rebinds it.
    func relinkNextMissingMedia() async {
        await documentController.relinkNextMissingMedia(model: self)
    }

    /// Records a successful security-scoped start, keeping exactly one outstanding access per URL.
    func retainAccess(_ url: URL, didStart: Bool) {
        documentController.retainAccess(url, didStart: didStart, model: self)
    }

    /// Whether the current saved single-file document can be converted to a bundle.
    var canConvertToBundle: Bool {
        documentController.canConvertToBundle(model: self)
    }

    /// Converts the current single-file project into a `.lcbundle` package.
    func convertToBundle(to bundleURL: URL) async {
        await documentController.convertToBundle(to: bundleURL, model: self)
    }
}
