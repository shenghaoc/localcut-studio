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
        lastBundleFingerprints = FingerprintIndex()
    }

    /// Reads and opens either a `.lcstudio` document or a `.lcbundle` package.
    /// The file read happens off the main actor; reconstruction (which touches
    /// the player/model) happens back on it.
    ///
    /// Sandbox note: for a `.lcbundle`, the outer URL's security-scoped access
    /// is retained for the lifetime of the session — see `load(document:…)`'s
    /// post-`releaseSession` retain. The bundle's grant covers every file
    /// inside, and bundled `MediaRef`s do not carry their own bookmarks.
    func open(url: URL) async {
        // Start access for the bundle directory or single-file document. For
        // bundles, the access is *not* stopped here — `load(document:…)` moves
        // ownership of the start into the new session (post-`releaseSession`)
        // so further reads off `assets/<id>.<ext>` keep working. For
        // single-file documents the local defer stops it after the JSON read.
        let initialAccess = url.startAccessingSecurityScopedResource()
        let isBundle = ProjectBundle.isBundle(url: url)
        defer {
            if !isBundle, initialAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            if isBundle {
                let bundleURL = url
                let raw = try await Task.detached {
                    try ProjectBundle.readData(url: bundleURL)
                }.value
                let contents = try ProjectBundle.decode(raw)
                let mismatches = ProjectBundle.mismatches(in: url, against: contents.fingerprints)
                lastBundleFingerprints = contents.fingerprints
                // Hand the bundle's outer access into the freshly-reset session
                // via `load`, which retains it after `releaseSession()`.
                await load(document: contents.document, from: url, bundleURL: url,
                           bundleAccessDidStart: initialAccess,
                           externallyEditedAssets: mismatches)
            } else {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                let document = try ProjectDocument(data: data)
                lastBundleFingerprints = FingerprintIndex()
                await load(document: document, from: url, bundleURL: nil,
                           externallyEditedAssets: [])
            }
        } catch {
            statusMessage = "Open failed: \(error.localizedDescription)"
        }
    }

    /// Rebuilds the runtime project from a decoded document, resolving media
    /// bookmarks. Clips whose media can't be resolved are preserved and surfaced
    /// for relinking — never silently dropped (R1.3).
    ///
    /// `bundleURL` is the root of a `.lcbundle` directory when opening a bundle,
    /// `nil` for legacy `.lcstudio` single-file documents. Bundled `MediaRef`s
    /// (those with `bundleRelativePath`) resolve directly off the bundle's outer
    /// URL — see `Sandbox` in the project-bundles design.
    ///
    /// `bundleAccessDidStart` carries the result of the caller's
    /// `startAccessingSecurityScopedResource()` on `bundleURL` so the freshly-
    /// reset session can take ownership of that start (`releaseSession` clears
    /// the previous session's accessedURLs first; we re-insert ours after).
    ///
    /// `externallyEditedAssets` lists bundle-relative paths whose SHA-256 no
    /// longer matches the recorded fingerprint; the loader surfaces a status
    /// note so the user knows their media drifted underneath the project.
    func load(document: ProjectDocument, from url: URL?,
              bundleURL: URL? = nil,
              bundleAccessDidStart: Bool = false,
              externallyEditedAssets: [String] = []) async {
        releaseSession()

        // Hand the bundle's outer security-scoped access into the new session.
        // `releaseSession()` cleared the previous session's accessedURLs, so
        // we insert the bundle URL now — it stays alive until the next swap.
        if let bundleURL, bundleAccessDidStart {
            retainAccess(bundleURL, didStart: true)
        }

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
            if let item = resolveMedia(ref, bundleURL: bundleURL) {
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
        if !externallyEditedAssets.isEmpty {
            notes.append("\(externallyEditedAssets.count) bundled asset(s) changed externally — re-import or accept on next save")
        }
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

    /// Resolves a media reference and reconstructs a `MediaItem` from cached
    /// metadata (no asset re-decode). Two paths:
    ///
    /// - **Bundled** (`ref.bundleRelativePath != nil` and `bundleURL` provided):
    ///   resolve to `bundleURL/<bundleRelativePath>` directly. The bundle's
    ///   outer URL is the sandbox grant; no per-file security-scoped bookmark
    ///   is required.
    /// - **External** (otherwise): the existing security-scoped bookmark path.
    ///
    /// Returns `nil` if the file can't be reached, so the caller can route it
    /// to the relink flow.
    private func resolveMedia(_ ref: MediaRef, bundleURL: URL?) -> MediaItem? {
        // Bundled asset: the bundle URL grants access; we read off the bundle root.
        if let relative = ref.bundleRelativePath, let bundleURL {
            let fileURL = bundleURL.appendingPathComponent(relative)
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                // The asset went missing from the bundle (manual deletion); fall
                // through to the bookmark path if one was also recorded.
                return ref.bookmark.isEmpty ? nil : resolveMediaViaBookmark(ref)
            }
            let item = MediaItem(url: fileURL, id: ref.id)
            populate(item: item, from: ref)
            item.bundleRelativePath = relative
            // Bundled media doesn't carry an own bookmark — the bundle is the grant.
            item.bookmark = nil
            return item
        }
        return resolveMediaViaBookmark(ref)
    }

    private func resolveMediaViaBookmark(_ ref: MediaRef) -> MediaItem? {
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
        populate(item: item, from: ref)
        item.bookmark = isStale
            ? (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            : ref.bookmark
        return item
    }

    private func populate(item: MediaItem, from ref: MediaRef) {
        item.name = ref.displayName
        item.duration = ref.duration.cmTime.sanitized
        item.naturalSize = CGSize(width: ref.naturalWidth, height: ref.naturalHeight).sanitized
        item.preferredTransform = ref.preferredTransform.cgTransform.sanitized
        item.hasVideo = ref.hasVideo
        item.hasAudio = ref.hasAudio
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
        if url.pathExtension == ProjectBundleLayout.fileExtension {
            await writeBundle(to: url)
        } else {
            await writeSingleFile(to: url)
        }
    }

    private func writeSingleFile(to url: URL) async {
        // The destination may be a security-scoped URL (panel/bookmark); access
        // must be held for the duration of the write under the sandbox.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Snapshot the mutation revision with the data: if the user keeps
            // editing during the off-main write, those edits aren't in `data`,
            // so we must not mark the document clean.
            let savedRevision = mutationRevision
            let data = try encodedDocument(forBundle: false)
            // Atomic write so a failure never corrupts the previous file (R4.1).
            try await Task.detached { try data.write(to: url, options: .atomic) }.value
            adoptSaved(url: url, cleanIfRevision: savedRevision)
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Writes the project to a `.lcbundle` directory: copies bundled media into
    /// `assets/`, fingerprints them, then writes `project.json`. The skip-recopy
    /// fast path checks every source's current SHA-256 against the previously-
    /// stored fingerprint, so repeat saves don't re-touch media that hasn't
    /// changed (R3.2).
    private func writeBundle(to bundleURL: URL) async {
        let scoped = bundleURL.startAccessingSecurityScopedResource()
        defer { if scoped { bundleURL.stopAccessingSecurityScopedResource() } }
        do {
            let savedRevision = mutationRevision
            // Decide which media are *bundled* (default for everything currently
            // resolved on disk) vs *external-only* (kept via bookmark). The
            // current heuristic: any resolved MediaItem is bundled. The
            // "Don't copy" import path will set `bundleRelativePath = nil`
            // explicitly on the item to opt out.
            let bundledMedia: [ProjectBundle.BundledMedia] = project.mediaItems.compactMap { item in
                let relative = bundleRelativePath(for: item)
                guard let relative else { return nil }
                item.bundleRelativePath = relative
                return ProjectBundle.BundledMedia(
                    mediaID: item.id,
                    sourceURL: item.url,
                    bundleRelativePath: relative)
            }
            let projectJSON = try encodedDocument(forBundle: true)
            let previous = lastBundleFingerprints
            let bundleURLCopy = bundleURL
            let index = try await Task.detached {
                try ProjectBundle.write(projectJSON: projectJSON, to: bundleURLCopy,
                                        bundledMedia: bundledMedia,
                                        previousFingerprints: previous)
            }.value
            lastBundleFingerprints = index
            adoptSaved(url: bundleURL, cleanIfRevision: savedRevision)
            statusMessage = "Saved \(bundleURL.lastPathComponent)."
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
            if url.pathExtension == ProjectBundleLayout.fileExtension {
                let bundledMedia: [ProjectBundle.BundledMedia] = project.mediaItems.compactMap { item in
                    guard let relative = bundleRelativePath(for: item) else { return nil }
                    item.bundleRelativePath = relative
                    return ProjectBundle.BundledMedia(
                        mediaID: item.id,
                        sourceURL: item.url,
                        bundleRelativePath: relative)
                }
                let projectJSON = try encodedDocument(forBundle: true)
                let index = try ProjectBundle.write(projectJSON: projectJSON,
                                                    to: url,
                                                    bundledMedia: bundledMedia,
                                                    previousFingerprints: lastBundleFingerprints)
                lastBundleFingerprints = index
            } else {
                let data = try encodedDocument(forBundle: false)
                try data.write(to: url, options: .atomic)
            }
            adoptSaved(url: url)
            statusMessage = "Saved \(url.lastPathComponent)."
            return true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    private func encodedDocument(forBundle: Bool) throws -> Data {
        try makeDocumentForSave(forBundle: forBundle).encoded()
    }

    /// Builds the document to persist. Unresolved media refs are carried through
    /// so saving before relinking never drops the references (and metadata) that
    /// still-missing media — and the clips that point at it — depend on.
    ///
    /// `forBundle == true` writes `schemaVersion = 3` + `bundleFormat = "1"`;
    /// otherwise the single-file `schemaVersion = 2` is preserved so older
    /// builds keep opening freshly-written `.lcstudio` documents.
    func makeDocumentForSave(forBundle: Bool = false) -> ProjectDocument {
        ensureBookmarks(forBundle: forBundle)
        var document = ProjectDocument(project: project)
        document.schemaVersion = forBundle
            ? ProjectDocument.currentSchemaVersion
            : ProjectDocument.singleFileSchemaVersion
        document.bundleFormat = forBundle ? ProjectDocument.currentBundleFormat : nil
        if !forBundle {
            // Single-file save: drop any bundle-relative paths that were set
            // for the previous bundle save (a Save As back to .lcstudio should
            // not leak bundle-internal paths into the JSON).
            document.media = document.media.map { ref in
                var copy = ref
                copy.bundleRelativePath = nil
                return copy
            }
        }
        document.media.append(contentsOf: unresolvedMedia)
        return document
    }

    /// Bundle-relative path for `item` if it should be copied into the bundle.
    /// Returns `nil` for items the user has explicitly opted out of bundling
    /// (their `bundleRelativePath` is left `nil` by the import path).
    private func bundleRelativePath(for item: MediaItem) -> String? {
        // When the item already carries an explicit choice (set by a future
        // "Don't copy" import option), respect it. Otherwise default to bundling.
        if let existing = item.bundleRelativePath { return existing }
        let ext = item.url.pathExtension
        return ProjectBundleLayout.assetRelativePath(mediaID: item.id, sourceExtension: ext)
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
    ///
    /// On the bundle save path, media that the user has chosen to include in the
    /// bundle does not need a bookmark — the bundle's outer URL is the sandbox
    /// grant. We still record bookmarks for any item that will end up as an
    /// external-only ref (`bundleRelativePath == nil`), and unconditionally for
    /// the single-file save path.
    private func ensureBookmarks(forBundle: Bool = false) {
        for item in project.mediaItems where item.bookmark == nil {
            if forBundle && item.bundleRelativePath != nil { continue }
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

    // MARK: Bundle conversion

    /// Whether the current document can be converted to a bundle. True when the
    /// document is a saved single-file `.lcstudio` (a fresh unsaved doc goes
    /// straight to the bundle via Save As; an already-bundled doc has nothing
    /// to convert).
    var canConvertToBundle: Bool {
        guard let url = documentURL else { return false }
        return url.pathExtension == ProjectDocument.fileExtension
    }

    /// Converts the current single-file project into a `.lcbundle` package at
    /// `bundleURL`. Copies every resolved media item into `assets/`, fingerprints
    /// them, and writes `project.json`. The **original `.lcstudio` file is left
    /// untouched** — the user verifies the bundle, then deletes the old file
    /// manually if they choose (R4.2). Adopts the new bundle URL as the current
    /// document URL; further saves go into the bundle.
    ///
    /// Undo history is preserved (R4.3) — Convert does not call `releaseSession`
    /// or `undoManager.removeAllActions()`, so every edit made before the
    /// conversion is still undoable afterwards.
    func convertToBundle(to bundleURL: URL) async {
        let scoped = bundleURL.startAccessingSecurityScopedResource()
        defer { if scoped { bundleURL.stopAccessingSecurityScopedResource() } }
        do {
            // Stamp a bundle-relative path onto every currently-resolved media
            // item so the document JSON we produce already references the
            // bundled copies (the ones we're about to write).
            let bundledMedia: [ProjectBundle.BundledMedia] = project.mediaItems.compactMap { item in
                let ext = item.url.pathExtension
                let relative = ProjectBundleLayout.assetRelativePath(
                    mediaID: item.id, sourceExtension: ext)
                item.bundleRelativePath = relative
                return ProjectBundle.BundledMedia(
                    mediaID: item.id, sourceURL: item.url, bundleRelativePath: relative)
            }
            let projectJSON = try encodedDocument(forBundle: true)
            let bundleURLCopy = bundleURL
            let previous = lastBundleFingerprints
            let index = try await Task.detached {
                try ProjectBundle.write(projectJSON: projectJSON, to: bundleURLCopy,
                                        bundledMedia: bundledMedia,
                                        previousFingerprints: previous)
            }.value
            lastBundleFingerprints = index
            adoptSaved(url: bundleURL)
            statusMessage = "Converted to bundle — original .lcstudio left in place."
        } catch {
            statusMessage = "Convert failed: \(error.localizedDescription)"
        }
    }
}
