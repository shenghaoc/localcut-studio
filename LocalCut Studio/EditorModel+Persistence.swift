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

    var name: String
    var media: [MediaItem]
    var renderSize: CGSize
    var frameRate: Double
    var videoTracks: [TrackClips]
    var audioTracks: [TrackClips]
    var selectedClipID: Clip.ID?
    var selectedTransitionClipID: Clip.ID?

    static func == (lhs: ProjectState, rhs: ProjectState) -> Bool {
        lhs.name == rhs.name
            && lhs.media.map(\.id) == rhs.media.map(\.id)
            && lhs.renderSize == rhs.renderSize
            && lhs.frameRate == rhs.frameRate
            && lhs.videoTracks == rhs.videoTracks
            && lhs.audioTracks == rhs.audioTracks
            && lhs.selectedClipID == rhs.selectedClipID
            && lhs.selectedTransitionClipID == rhs.selectedTransitionClipID
    }
}

// MARK: - Undo / redo

extension EditorModel {

    /// How the preview should refresh after an undoable mutation.
    enum RebuildMode { case immediate, debounced }

    /// Captures the current arrangement for undo.
    func captureState() -> ProjectState {
        ProjectState(
            name: project.name,
            media: project.mediaItems,
            renderSize: project.renderSize,
            frameRate: project.frameRate,
            videoTracks: project.videoTracks.map {
                ProjectState.TrackClips(trackID: $0.id, name: $0.name, isMuted: $0.isMuted, clips: $0.clips)
            },
            audioTracks: project.audioTracks.map {
                ProjectState.TrackClips(trackID: $0.id, name: $0.name, isMuted: $0.isMuted, clips: $0.clips)
            },
            selectedClipID: selectedClipID,
            selectedTransitionClipID: selectedTransitionClipID)
    }

    /// Restores a previously captured arrangement. Track identities are stable
    /// within a session, so clips are matched back onto their tracks by ID.
    func applyState(_ state: ProjectState) {
        project.name = state.name
        project.mediaItems = state.media
        project.renderSize = state.renderSize
        project.frameRate = state.frameRate
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
        selectedClipID = state.selectedClipID
        selectedTransitionClipID = state.selectedTransitionClipID
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

    /// Performs one step of a continuous gesture (slider drag, edge trim, clip
    /// move). The `before` snapshot is captured once at the start of the gesture
    /// and a single undo step is committed shortly after the gesture settles.
    func performCoalescedUndoable(_ name: String, rebuild mode: RebuildMode, mutate: () -> Void) {
        if coalescedUndoBefore == nil {
            coalescedUndoBefore = captureState()
            coalescedUndoName = name
        }
        mutate()
        markDirty()
        switch mode {
        case .immediate: Task { await rebuild() }
        case .debounced: rebuildDebounced()
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
        let after = captureState()
        guard before != after else { return }
        registerUndo(name: name, before: before, after: after)
    }

    /// Registers a reversible swap between two snapshots, re-registering its
    /// inverse on invocation so redo works (the standard recursive pattern).
    private func registerUndo(name: String, before: ProjectState, after: ProjectState) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.applyState(before)
                model.markDirty()
                model.registerUndo(name: name, before: after, after: before)
                Task { await model.rebuild() }
                model.refreshUndoFlags()
            }
        }
        undoManager.setActionName(name)
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

    func markDirty() { isDirty = true }
}

// MARK: - Document lifecycle

extension EditorModel {

    /// Replaces the current project with an empty one (File ▸ New).
    func newDocument() {
        releaseSession()
        project.name = "Untitled"
        project.renderSize = CGSize(width: 1920, height: 1080)
        project.frameRate = 30
        project.videoTracks = [Track(name: "V1", kind: .video)]
        project.audioTracks = [Track(name: "A1", kind: .audio)]
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
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
        project.mediaItems.removeAll()
        selectedClipID = nil
        selectedMediaID = nil
        selectedTransitionClipID = nil
        unresolvedMedia = []
        undoManager.removeAllActions()
        coalescedCommitTask?.cancel()
        coalescedUndoBefore = nil
        coalescedUndoName = nil
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

        var unresolved: [MediaRef] = []
        for ref in document.media {
            if let item = resolveMedia(ref) {
                project.mediaItems.append(item)
            } else {
                unresolved.append(ref)
            }
        }

        project.videoTracks = makeTracks(from: document.videoTracks, kind: .video, fallbackName: "V1")
        project.audioTracks = makeTracks(from: document.audioTracks, kind: .audio, fallbackName: "A1")

        documentURL = url
        unresolvedMedia = unresolved
        isDirty = false
        undoManager.removeAllActions()
        refreshUndoFlags()

        await rebuild()
        for item in project.mediaItems { await generateThumbnail(for: item) }

        if unresolved.isEmpty {
            statusMessage = "Opened \(project.name)."
        } else {
            statusMessage = "Opened \(project.name) — \(unresolved.count) media file(s) need relinking."
        }
    }

    private func makeTracks(from docs: [TrackDoc], kind: TrackKind, fallbackName: String) -> [Track] {
        guard !docs.isEmpty else { return [Track(name: fallbackName, kind: kind)] }
        return docs.map { doc in
            let track = Track(name: doc.name.isEmpty ? fallbackName : doc.name, kind: kind)
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
        if access { accessedURLs.insert(url) }

        let item = MediaItem(url: url, id: ref.id)
        item.name = ref.displayName
        item.duration = ref.duration.cmTime
        item.naturalSize = CGSize(width: ref.naturalWidth, height: ref.naturalHeight)
        item.preferredTransform = ref.preferredTransform.cgTransform
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
        ensureBookmarks()
        let document = ProjectDocument(project: project)
        do {
            let data = try document.encoded()
            // Atomic write so a failure never corrupts the previous file (R4.1).
            try await Task.detached { try data.write(to: url, options: .atomic) }.value
            documentURL = url
            project.name = url.deletingPathExtension().lastPathComponent
            isDirty = false
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
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
    func relinkNextMissingMedia() {
        guard let ref = unresolvedMedia.first else { return }

        let panel = NSOpenPanel()
        panel.message = "Locate “\(ref.displayName)”."
        panel.prompt = "Relink"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let access = url.startAccessingSecurityScopedResource()
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            if access { url.stopAccessingSecurityScopedResource() }
            statusMessage = "Could not access \(url.lastPathComponent)."
            return
        }
        if access { accessedURLs.insert(url) }

        let item = MediaItem(url: url, id: ref.id)
        item.name = ref.displayName
        item.duration = ref.duration.cmTime
        item.naturalSize = CGSize(width: ref.naturalWidth, height: ref.naturalHeight)
        item.preferredTransform = ref.preferredTransform.cgTransform
        item.hasVideo = ref.hasVideo
        item.hasAudio = ref.hasAudio
        item.bookmark = bookmark
        project.mediaItems.append(item)
        unresolvedMedia.removeAll { $0.id == ref.id }
        markDirty()

        statusMessage = unresolvedMedia.isEmpty
            ? "Relinked \(item.name)."
            : "Relinked \(item.name) — \(unresolvedMedia.count) remaining."
        Task {
            await rebuild()
            await generateThumbnail(for: item)
        }
    }
}
