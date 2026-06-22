import Foundation
import AVFoundation
import CoreGraphics
import AppKit

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
    var renderSize: CGSize
    var frameRate: Double
    var workingColourSpace: WorkingColourSpace
    var videoTracks: [TrackClips]
    var audioTracks: [TrackClips]
    var captionTracks: [CaptionTrackSnapshot]
    var markers: [TimelineMarker]
    /// Master-bus gain (linear, 0…2). Per-clip volume envelopes ride along
    /// inside `clips`; only bus-level parameters live here directly.
    var masterGain: Float
    /// Per-audio-track pan + gain on the bus.
    var trackInputs: [TrackInput]
    var selectedClipID: Clip.ID?
    var selectedTransitionClipID: Clip.ID?
    var selectedMarkerID: TimelineMarker.ID?

    static func == (lhs: ProjectState, rhs: ProjectState) -> Bool {
        lhs.name == rhs.name
            && lhs.media.map(\.id) == rhs.media.map(\.id)
            && lhs.unresolvedMedia == rhs.unresolvedMedia
            && lhs.renderSize == rhs.renderSize
            && lhs.frameRate == rhs.frameRate
            && lhs.workingColourSpace == rhs.workingColourSpace
            && lhs.videoTracks == rhs.videoTracks
            && lhs.audioTracks == rhs.audioTracks
            && lhs.captionTracks == rhs.captionTracks
            && lhs.markers == rhs.markers
            && lhs.masterGain == rhs.masterGain
            && lhs.trackInputs == rhs.trackInputs
            && lhs.selectedClipID == rhs.selectedClipID
            && lhs.selectedTransitionClipID == rhs.selectedTransitionClipID
            && lhs.selectedMarkerID == rhs.selectedMarkerID
    }
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
            renderSize: project.renderSize,
            frameRate: project.frameRate,
            workingColourSpace: project.workingColourSpace,
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
            masterGain: project.masterGain,
            trackInputs: project.trackInputs,
            selectedClipID: selectedClipID,
            selectedTransitionClipID: selectedTransitionClipID,
            selectedMarkerID: selectedMarkerID)
    }

    /// Restores a previously captured arrangement. Track identities are stable
    /// within a session, so clips are matched back onto their tracks by ID.
    func applyState(_ state: ProjectState) {
        project.name = state.name
        project.mediaItems = state.media
        unresolvedMedia = state.unresolvedMedia
        project.renderSize = state.renderSize
        project.frameRate = state.frameRate
        if project.workingColourSpace != state.workingColourSpace {
            project.workingColourSpace = state.workingColourSpace
            // Cached rasters were rendered in the previous space; drop them so
            // an undo across a Change Working Space step re-rasterises correctly.
            EffectCompositor.purgeCaptionRasterCache()
        }
        for snapshot in state.videoTracks {
            if let track = project.videoTracks.first(where: { $0.id == snapshot.trackID }) {
                track.name = snapshot.name
                track.isMuted = snapshot.isMuted
                track.clips = snapshot.clips
            }
        }
        for snapshot in state.audioTracks {
            if let track = project.audioTracks.first(where: { $0.id == snapshot.trackID }) {
                track.name = snapshot.name
                track.isMuted = snapshot.isMuted
                track.clips = snapshot.clips
            }
        }
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
        selectedClipID = state.selectedClipID
        selectedTransitionClipID = state.selectedTransitionClipID
        selectedMarkerID = state.selectedMarkerID
        reconcileAccessedURLs()
    }

    /// Keeps retained security-scoped access aligned with the restored media set:
    /// releases files an undo dropped, and re-acquires files a redo brought back
    /// (the restored items hold the same security-scoped URLs, which support
    /// repeated start/stop), so undo neither leaks tokens nor breaks redo.
    private func reconcileAccessedURLs() {
        let active = Set(project.mediaItems.map(\.url))
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
    func registerImportUndo(name: String, before: ProjectState) {
        let after = captureState()
        guard before != after else { return }
        registerUndo(name: name, before: before, after: after)
    }

    /// Performs one step of a continuous gesture (slider drag, edge trim, clip
    /// move). The `before` snapshot is captured once at the start of the gesture
    /// and a single undo step is committed shortly after the gesture settles.
    /// A change of `name` or `target` ends the previous gesture first, so two
    /// adjacent gestures never fold into one undo step.
    func performCoalescedUndoable(_ name: String, target: AnyHashable?,
                                  rebuild mode: RebuildMode, mutate: () -> Void) {
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
    private func registerUndo(name: String, before: ProjectState, after: ProjectState) {
        // `groupsByEvent` is disabled (see init), so each top-level action gets
        // its own explicit group — one user action = one undo step regardless of
        // run-loop timing. While undoing/redoing, UndoManager already manages the
        // group that collects the inverse registration, so we don't open one.
        let opensGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.applyState(before)
                model.markDirty()
                model.registerUndo(name: name, before: after, after: before)
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
        releaseSession()
        project.name = "Untitled"
        project.renderSize = CGSize(width: 1920, height: 1080)
        project.frameRate = 30
        project.workingColourSpace = .sRGB
        project.videoTracks = [Track(name: "V1", kind: .video)]
        project.audioTracks = [Track(name: "A1", kind: .audio)]
        project.captionTracks = []
        project.markers = []
        project.masterGain = 1
        project.trackInputs = []
        documentURL = nil
        isDirty = false
        unresolvedMedia = []
        totalDuration = 0
        currentTime = 0
        player.replaceCurrentItem(with: nil)
        refreshUndoFlags()
        statusMessage = "New project."
    }

    /// Stops every retained security-scoped resource and clears session state.
    /// Called before loading another document and on teardown.
    func releaseSession() {
        // Invalidate any in-flight async import/relink so it can't leak access
        // into, or append clips onto, the session that replaces this one.
        sessionGeneration &+= 1
        // A session swap must not let the replacement document's preview auto-resume
        // from a stale playback flag (rebuild() resumes when `isPlaying` is true).
        player.pause()
        isPlaying = false
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
        // Drop every cached post-effect frame: the replacement document brings
        // new clip ids whose keys would never collide, but the prior bytes
        // would sit at the back of the LRU until natural eviction.
        RenderCache.shared.purge()
        project.mediaItems.removeAll()
        project.captionTracks.removeAll()
        project.markers.removeAll()
        project.masterGain = 1
        project.trackInputs = []
        selectedClipID = nil
        selectedMediaID = nil
        selectedTransitionClipID = nil
        selectedMarkerID = nil
        unresolvedMedia = []
        undoManager.removeAllActions()
        coalescedCommitTask?.cancel()
        activeRebuildTask?.cancel()
        pendingRebuildTask?.cancel()
        coalescedUndoBefore = nil
        coalescedUndoName = nil
        coalescedUndoTarget = nil
        audioBus.teardownLive()
        audioBus.teardownOffline()
    }

    /// Reads and opens a `.lcstudio` document. The file read happens off the main
    /// actor; reconstruction (which touches the player/model) happens back on it.
    func open(url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            let document = try ProjectDocument(data: data)
            await load(document: document, from: url)
        } catch {
            statusMessage = "Open failed: \(error.localizedDescription)"
        }
    }

    /// Rebuilds the runtime project from a decoded document, resolving media
    /// bookmarks. Clips whose media can't be resolved are preserved and surfaced
    /// for relinking — never silently dropped (R1.3).
    func load(document: ProjectDocument, from url: URL?) async {
        releaseSession()

        project.name = url?.deletingPathExtension().lastPathComponent ?? document.name
        project.renderSize = CGSize(width: document.renderWidth, height: document.renderHeight)
        project.frameRate = document.frameRate
        // Always purge the caption-raster cache on load: cached rasters from the
        // previous session were rendered against the previous working space,
        // and reopening a project with the same line IDs / text / style /
        // render size could otherwise reuse them under the new space.
        EffectCompositor.purgeCaptionRasterCache()
        project.workingColourSpace = document.workingColourSpace

        var unresolved: [MediaRef] = []
        var refreshedBookmark = false
        for ref in document.media {
            if let item = resolveMedia(ref) {
                // resolveMedia regenerates the bookmark when the stored one resolved
                // stale; flag the document dirty so the fresh bookmark is persisted
                // on the next save instead of being re-derived on every launch.
                if item.bookmark != ref.bookmark { refreshedBookmark = true }
                project.mediaItems.append(item)
            } else {
                unresolved.append(ref)
            }
        }

        project.videoTracks = makeTracks(from: document.videoTracks, kind: .video, fallbackName: "V1")
        project.audioTracks = makeTracks(from: document.audioTracks, kind: .audio, fallbackName: "A1")
        project.captionTracks = document.captionTracks.map { $0.makeTrack() }
        // Markers serialise as a flat sorted array; re-sort on the way in so a
        // hand-edited or migrated document with unsorted entries can't break
        // ordered draw / lookup code.
        project.markers = document.markers.sorted { $0.time < $1.time }
        project.masterGain = document.audioBus.masterGain
        project.trackInputs = document.audioBus.trackInputs.map(\.trackInput)

        // A document from a newer schema would lose its future-only fields if we
        // re-saved it as the current version, so don't adopt its URL — Save then
        // prompts for a new location rather than silently overwriting it (R4.2).
        let isNewerSchema = document.schemaVersion > ProjectDocument.currentSchemaVersion
        documentURL = isNewerSchema ? nil : url
        unresolvedMedia = unresolved
        isDirty = isNewerSchema || refreshedBookmark
        undoManager.removeAllActions()
        refreshUndoFlags()

        await rebuild()
        // Thumbnails are non-blocking so a multi-clip project opens immediately.
        for item in project.mediaItems { Task { await item.loadThumbnail() } }

        var notes: [String] = []
        if isNewerSchema { notes.append("saved in a newer format — saving downconverts to this version") }
        if refreshedBookmark { notes.append("media moved — save to update its location") }
        if !unresolved.isEmpty { notes.append("\(unresolved.count) media file(s) need relinking") }
        statusMessage = notes.isEmpty
            ? "Opened \(project.name)."
            : "Opened \(project.name) — " + notes.joined(separator: "; ") + "."
    }

    private func makeTracks(from docs: [TrackDoc], kind: TrackKind, fallbackName: String) -> [Track] {
        guard !docs.isEmpty else { return [Track(name: fallbackName, kind: kind)] }
        return docs.map { doc in
            // Carry the persisted UUID across the restore so audio-bus
            // `TrackInput` rows keyed by `Track.id` keep matching after open.
            let track = Track(id: doc.id, name: doc.name.isEmpty ? fallbackName : doc.name, kind: kind)
            track.isMuted = doc.isMuted
            track.clips = doc.clips.map { $0.makeClip() }
            return track
        }
    }

    /// Resolves a media reference's bookmark and reconstructs a `MediaItem` from
    /// cached metadata (no asset re-decode). Returns `nil` if the file can't be
    /// reached, so the caller can route it to the relink flow.
    private func resolveMedia(_ ref: MediaRef) -> MediaItem? {
        guard !ref.bookmark.isEmpty else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: ref.bookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        guard access || FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        retainAccess(url, didStart: access)

        let item = MediaItem(url: url, id: ref.id)
        item.name = ref.displayName
        item.duration = ref.duration.cmTime.sanitized
        item.naturalSize = CGSize(width: ref.naturalWidth, height: ref.naturalHeight).sanitized
        item.preferredTransform = ref.preferredTransform.cgTransform.sanitized
        item.hasVideo = ref.hasVideo
        item.hasAudio = ref.hasAudio
        item.bookmark = isStale
            ? (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            : ref.bookmark
        return item
    }

    // MARK: Save

    /// Saves to the current document URL, or does nothing if none is set yet
    /// (the caller should fall back to Save As).
    func save() async {
        guard let url = documentURL else { return }
        await write(to: url)
    }

    /// Saves to a new location and adopts it as the document URL.
    func saveAs(url: URL) async {
        await write(to: url)
    }

    private func write(to url: URL) async {
        // The destination may be a security-scoped URL (panel/bookmark); access
        // must be held for the duration of the write under the sandbox.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Snapshot the mutation revision with the data: if the user keeps
            // editing during the off-main write, those edits aren't in `data`,
            // so we must not mark the document clean.
            let savedRevision = mutationRevision
            let data = try encodedDocument()
            // Atomic write so a failure never corrupts the previous file (R4.1).
            try await Task.detached { try data.write(to: url, options: .atomic) }.value
            adoptSaved(url: url, cleanIfRevision: savedRevision)
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Synchronous save used by the close prompt, where the result must be known
    /// before `windowShouldClose` returns. The document is small JSON, so the
    /// atomic write on the main actor is acceptable here.
    func writeSynchronously(to url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try encodedDocument()
            try data.write(to: url, options: .atomic)
            adoptSaved(url: url)
            statusMessage = "Saved \(url.lastPathComponent)."
            return true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    private func encodedDocument() throws -> Data {
        try makeDocumentForSave().encoded()
    }

    /// Builds the document to persist. Unresolved media refs are carried through
    /// so saving before relinking never drops the references (and metadata) that
    /// still-missing media — and the clips that point at it — depend on.
    func makeDocumentForSave() -> ProjectDocument {
        ensureBookmarks()
        var document = ProjectDocument(project: project)
        document.media.append(contentsOf: unresolvedMedia)
        return document
    }

    /// Adopts a saved URL. Only clears the dirty flag when no edit has landed
    /// since the saved snapshot (`cleanIfRevision`), so edits made during an
    /// async write aren't lost to a skipped close prompt.
    private func adoptSaved(url: URL, cleanIfRevision revision: Int? = nil) {
        documentURL = url
        project.name = url.deletingPathExtension().lastPathComponent
        if revision == nil || revision == mutationRevision { isDirty = false }
    }

    /// Ensures every media item carries a security-scoped bookmark before saving.
    private func ensureBookmarks() {
        for item in project.mediaItems where item.bookmark == nil {
            item.bookmark = try? item.url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil)
        }
    }

    // MARK: Relink

    /// Prompts the user to locate the first unresolved media file and rebinds it
    /// to its original identity so referencing clips render again (R1.3).
    func relinkNextMissingMedia() async {
        guard let ref = unresolvedMedia.first else { return }

        let panel = NSOpenPanel()
        panel.message = "Locate “\(ref.displayName)”."
        panel.prompt = "Relink"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let generation = sessionGeneration
        let access = url.startAccessingSecurityScopedResource()
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            if access { url.stopAccessingSecurityScopedResource() }
            statusMessage = "Could not access \(url.lastPathComponent)."
            return
        }

        // Read metadata from the chosen file rather than trusting the stale ref,
        // so a wrong/short file is reflected (and warned about) instead of
        // silently mismatching clip source ranges.
        let item = MediaItem(url: url, id: ref.id)
        item.name = ref.displayName
        do {
            item.duration = try await item.asset.load(.duration).sanitized
            if let videoTrack = try await item.asset.loadTracks(withMediaType: .video).first {
                item.hasVideo = true
                item.naturalSize = try await videoTrack.load(.naturalSize).sanitized
                item.preferredTransform = try await videoTrack.load(.preferredTransform).sanitized
            }
            item.hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            statusMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        // Bail if the document was replaced while metadata loaded (see importMedia).
        guard sessionGeneration == generation else {
            if access { url.stopAccessingSecurityScopedResource() }
            return
        }
        retainAccess(url, didStart: access)
        item.bookmark = bookmark

        // Undoable so the media item and the relink queue stay in sync across
        // undo/redo (a non-undoable relink could be silently dropped by a later
        // undo that restores a pre-relink media list).
        performUndoable("Relink Media") {
            project.mediaItems.append(item)
            unresolvedMedia.removeAll { $0.id == ref.id }
        }

        let mismatched = (ref.hasVideo && !item.hasVideo) || (ref.hasAudio && !item.hasAudio)
        if mismatched {
            statusMessage = "Relinked \(item.name), but its tracks differ from the original — some clips may not render."
        } else {
            statusMessage = unresolvedMedia.isEmpty
                ? "Relinked \(item.name)."
                : "Relinked \(item.name) — \(unresolvedMedia.count) remaining."
        }
        await rebuild()
        await item.loadThumbnail()
    }

    /// Records a successful security-scoped start, keeping exactly one outstanding
    /// access per URL. A redundant start (same file accessed again) is balanced
    /// immediately so the kernel refcount matches the single stop on teardown.
    func retainAccess(_ url: URL, didStart: Bool) {
        guard didStart else { return }
        if accessedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
        } else {
            accessedURLs.insert(url)
        }
    }
}
