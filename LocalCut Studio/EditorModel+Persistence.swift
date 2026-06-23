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
        if let bundleURL = bundleAccessURL {
            bundleURL.stopAccessingSecurityScopedResource()
            bundleAccessURL = nil
        }
    }

    /// Adopts ownership of a successful `startAccessingSecurityScopedResource()`
    /// on `bundleURL` for the session. Stored separately from `accessedURLs`
    /// so `reconcileAccessedURLs` cannot revoke the bundle's grant on undo /
    /// redo (the per-file `accessedURLs` set is keyed off media item URLs,
    /// which always point *inside* the bundle, never at the directory itself).
    func adoptBundleAccess(_ bundleURL: URL, didStart: Bool) {
        guard didStart else { return }
        // A previous bundle access on a different URL must be released first.
        if let existing = bundleAccessURL, existing != bundleURL {
            existing.stopAccessingSecurityScopedResource()
        }
        // If we already hold the SAME URL, balance the redundant start so the
        // kernel ref-count matches the single stop on teardown.
        if bundleAccessURL == bundleURL {
            bundleURL.stopAccessingSecurityScopedResource()
        } else {
            bundleAccessURL = bundleURL
        }
    }

    /// Reads and opens either a `.lcstudio` document or a `.lcbundle` package.
    /// The file read and any fingerprint verification happen off the main
    /// actor; reconstruction (which touches the player/model) happens back on
    /// it.
    ///
    /// Sandbox note: for a `.lcbundle`, the outer URL's security-scoped access
    /// is retained for the lifetime of the session — see `load(document:…)`'s
    /// post-`releaseSession` retain. The bundle's grant covers every file
    /// inside, and bundled `MediaRef`s do not carry their own bookmarks.
    func open(url: URL) async {
        // Start access for the bundle directory or single-file document. For a
        // bundle, ownership of this start is *transferred* to the new session
        // (post-`releaseSession`) so further reads off `assets/<id>.<ext>` keep
        // working past `open()`'s return. The `didTransferAccess` guard makes
        // sure a read/decode failure still stops the scope here — otherwise an
        // open-failure path would leak a kernel-level access for the rest of
        // the process.
        let initialAccess = url.startAccessingSecurityScopedResource()
        let isBundle = ProjectBundle.isBundle(url: url)
        var didTransferAccess = false
        defer {
            if initialAccess, !didTransferAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            if isBundle {
                let bundleURL = url
                // Both the metadata read AND the fingerprint verification run
                // off the main actor. The verification SHA's every asset; on
                // large projects this is the slowest step of the open path.
                let (raw, mismatches) = try await Task.detached {
                    let data = try ProjectBundle.readData(url: bundleURL)
                    let parsedFingerprints = data.fingerprintsJSON
                        .flatMap { try? FingerprintIndex(data: $0) }
                        ?? FingerprintIndex()
                    let mismatched = ProjectBundle.mismatches(in: bundleURL,
                                                              against: parsedFingerprints)
                    return (data, mismatched)
                }.value
                let contents = try ProjectBundle.decode(raw)
                // Hand the bundle's outer access into the freshly-reset session
                // via `load`, which retains it after `releaseSession()`.
                await load(document: contents.document, from: url, bundleURL: url,
                           bundleAccessDidStart: initialAccess,
                           bundleFingerprints: contents.fingerprints,
                           externallyEditedAssets: mismatches)
                didTransferAccess = initialAccess
            } else {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                let document = try ProjectDocument(data: data)
                await load(document: document, from: url, bundleURL: nil,
                           bundleFingerprints: FingerprintIndex(),
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
    /// `bundleFingerprints` is the index parsed from the bundle's
    /// `fingerprints.json`. We adopt it **after** `releaseSession()` (which
    /// resets the cache to empty) so the next bundle save's fast path can use
    /// it; assigning before `releaseSession` would wipe the value.
    ///
    /// `externallyEditedAssets` lists bundle-relative paths whose SHA-256 no
    /// longer matches the recorded fingerprint; the loader surfaces a status
    /// note so the user knows their media drifted underneath the project.
    func load(document: ProjectDocument, from url: URL?,
              bundleURL: URL? = nil,
              bundleAccessDidStart: Bool = false,
              bundleFingerprints: FingerprintIndex = FingerprintIndex(),
              externallyEditedAssets: [String] = []) async {
        releaseSession()

        // Order matters: releaseSession() clears `lastBundleFingerprints`, so
        // the freshly-parsed index has to be assigned *after* it.
        lastBundleFingerprints = bundleFingerprints

        // Hand the bundle's outer security-scoped access into the new session.
        // Stored on `bundleAccessURL` (not in `accessedURLs`) so undo/redo's
        // `reconcileAccessedURLs` pass can't revoke it — that function only
        // touches the per-file set, which never contains the bundle root.
        if let bundleURL, bundleAccessDidStart {
            adoptBundleAccess(bundleURL, didStart: true)
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
            // Validate the path BEFORE appending: a corrupt or hostile
            // `project.json` could store `../escape.mov` and resolve to a URL
            // outside the bundle. Mirror the write-side guard.
            guard ProjectBundleLayout.isSafeAssetRelativePath(relative) else {
                return ref.bookmark.isEmpty ? nil : resolveMediaViaBookmark(ref)
            }
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
        // Hold the bundle URL's access for the lifetime of the session if
        // we're adopting it as the document URL (a Save As to a new bundle, or
        // a Save to an existing bundle whose access we may have lost between
        // documents). The session-end teardown pairs the stop. The local defer
        // only fires on failure.
        let scoped = bundleURL.startAccessingSecurityScopedResource()
        var didTransferAccess = false
        defer {
            if scoped, !didTransferAccess {
                bundleURL.stopAccessingSecurityScopedResource()
            }
        }
        // Capture original paths so we can restore them if the write fails,
        // leaving the in-memory model consistent with the on-disk state.
        let originalPaths = project.mediaItems.map { ($0, $0.bundleRelativePath) }
        do {
            let savedRevision = mutationRevision
            // Items the user wants bundled (default: every imported MediaItem)
            // get a bundle-relative path stamped on them; the rest stay
            // external-only and continue to use security-scoped bookmarks.
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

            // Replace bundled MediaItems with new instances pointed at the
            // bundled copies. Replacing — not mutating — preserves the
            // pre-save references held by any in-flight undo snapshot, so a
            // later undo restores the original external URLs / asset.
            replaceMediaItemsForBundle(at: bundleURL)
            adoptBundleAccess(bundleURL, didStart: scoped)
            didTransferAccess = scoped

            adoptSaved(url: bundleURL, cleanIfRevision: savedRevision)
            statusMessage = "Saved \(bundleURL.lastPathComponent)."
        } catch {
            for (item, path) in originalPaths {
                item.bundleRelativePath = path
            }
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Replaces every bundled `MediaItem` whose `url` is not already the
    /// bundled path with a NEW `MediaItem` (same id, same metadata, new url +
    /// fresh `AVURLAsset`) pointing at `bundleURL/<bundleRelativePath>`.
    ///
    /// Replacement — rather than in-place mutation of the existing object —
    /// matters for undo correctness: `ProjectState` captures `media` as an
    /// array of class references, so mutating an item's URL would silently
    /// retroactively edit every undo snapshot that holds that reference.
    /// New objects leave the snapshots' old references untouched.
    private func replaceMediaItemsForBundle(at bundleURL: URL) {
        project.mediaItems = project.mediaItems.map { item in
            guard let relative = item.bundleRelativePath else { return item }
            let bundled = bundleURL.appendingPathComponent(relative)
            if item.url.standardizedFileURL == bundled.standardizedFileURL {
                // Already at the bundled path — just drop the per-file bookmark
                // (the bundle's outer URL is the grant for everything inside).
                item.bookmark = nil
                return item
            }
            let replacement = MediaItem(url: bundled, id: item.id)
            replacement.name = item.name
            replacement.duration = item.duration
            replacement.naturalSize = item.naturalSize
            replacement.preferredTransform = item.preferredTransform
            replacement.hasVideo = item.hasVideo
            replacement.hasAudio = item.hasAudio
            replacement.bundleRelativePath = relative
            replacement.wantsBundling = item.wantsBundling
            replacement.thumbnail = item.thumbnail
            // No bookmark — the bundle grant covers contents.
            replacement.bookmark = nil
            return replacement
        }
    }

    /// Synchronous save used by the close prompt, where the result must be known
    /// before `windowShouldClose` returns. The document is small JSON, so the
    /// atomic write on the main actor is acceptable here.
    func writeSynchronously(to url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Capture original paths so the bundle branch can restore them on
        // failure, matching the transactional-safety pattern in writeBundle
        // and convertToBundle.
        let originalPaths = project.mediaItems.map { ($0, $0.bundleRelativePath) }
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
            for (item, path) in originalPaths {
                item.bundleRelativePath = path
            }
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
    /// Returns `nil` for items the user has opted out of bundling (the
    /// `wantsBundling` flag on `MediaItem`); those remain external-only and
    /// continue to use security-scoped bookmarks.
    ///
    /// The `wantsBundling` flag — not the `bundleRelativePath`'s nil-ness — is
    /// the source of truth here: `bundleRelativePath == nil` is also the state
    /// of a freshly-imported item that has not yet been placed in any bundle,
    /// which is *different* from "the user said don't copy".
    private func bundleRelativePath(for item: MediaItem) -> String? {
        guard item.wantsBundling else { return nil }
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
        // The Save panel grants access; for the bundle to remain readable past
        // this function (so preview/export keep working in the same session)
        // we hold the start and let `releaseSession`-on-next-swap pair the
        // stop. The local `defer` only fires on the failure paths below.
        let scoped = bundleURL.startAccessingSecurityScopedResource()
        var didTransferAccess = false
        defer {
            if scoped, !didTransferAccess {
                bundleURL.stopAccessingSecurityScopedResource()
            }
        }
        // Capture original paths so we can restore them if the conversion fails,
        // leaving the in-memory model consistent with the on-disk state.
        let originalPaths = project.mediaItems.map { ($0, $0.bundleRelativePath) }
        do {
            // Stamp a bundle-relative path onto every currently-resolved media
            // item the user wants bundled. Items with `wantsBundling == false`
            // stay external-only; their `bundleRelativePath` is cleared so a
            // previous bundle session's stale value can't leak into the new
            // document.
            let bundledMedia: [ProjectBundle.BundledMedia] = project.mediaItems.compactMap { item in
                guard item.wantsBundling else {
                    item.bundleRelativePath = nil
                    return nil
                }
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

            // Replace every bundled MediaItem with a fresh instance pointed
            // at the newly-written copy under assets/. Replacement — rather
            // than in-place mutation — preserves the pre-Convert references
            // held by any in-flight undo snapshot, so undoing a prior edit
            // past the conversion does not silently corrupt the captured
            // external URLs.
            replaceMediaItemsForBundle(at: bundleURL)
            // Retain the bundle URL's access on `bundleAccessURL` (separate
            // from the per-file `accessedURLs` set) so reads off `assets/`
            // keep working past this function's return and undo/redo's
            // `reconcileAccessedURLs` cannot revoke the directory grant.
            adoptBundleAccess(bundleURL, didStart: scoped)
            didTransferAccess = scoped

            adoptSaved(url: bundleURL)
            // The MediaItem URLs changed — refresh the preview composition so
            // playback reads from the bundled copies.
            await rebuild()
            statusMessage = "Converted to bundle — original .lcstudio left in place."
        } catch {
            for (item, path) in originalPaths {
                item.bundleRelativePath = path
            }
            statusMessage = "Convert failed: \(error.localizedDescription)"
        }
    }
}
