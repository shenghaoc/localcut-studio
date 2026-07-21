import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import LocalCutCore
import LocalCutPlatform

@MainActor
final class DocumentController {
    func newDocument(model: EditorModel) {
        // `releaseSession` already clears media, tracks, overlays, selections,
        // beat/silence state, access tokens, and preview. Only re-apply the
        // defaults that distinguish a fresh project from a released session.
        releaseSession(model: model)
        model.project.name = "Untitled"
        model.project.aspect = .widescreen16x9
        model.project.renderSize = CGSize(width: 1920, height: 1080)
        model.project.frameRate = 30
        model.project.workingColourSpace = .sRGB
        model.isDirty = false
        model.totalDuration = 0
        model.currentTime = 0
        model.refreshUndoFlags()
        model.statusMessage = "New project."
    }

    func releaseSession(model: EditorModel) {
        model.sessionGeneration &+= 1
        model.projectSessionLocation = .unsaved
        model.player.pause()
        model.isPlaying = false
        model.replacePreviewItem(with: nil)
        for url in model.accessedURLs { url.stopAccessingSecurityScopedResource() }
        model.accessedURLs.removeAll()
        RenderCache.shared.purge()
        PaddedBackgroundRenderer.purgeCache()
        model.project.mediaItems.removeAll()
        // Clear all tracks to prevent orphaned clips referencing deleted media.
        model.project.videoTracks = [Track(name: "V1", kind: .video)]
        model.project.audioTracks = [Track(name: "A1", kind: .audio)]
        model.project.captionTracks.removeAll()
        model.project.markers.removeAll()
        model.project.overlays.removeAll()
        model.project.overlayBookmarks.removeAll()
        model.project.overlayBundlePaths.removeAll()
        model.project.callouts.removeAll()
        model.project.paddedBackground = nil
        model.project.screencastEventLogs.removeAll()
        model.project.keystrokeOverlayClips.removeAll()
        model.project.sceneDoc = SceneDoc()
        model.project.layoutTracks = []
        model.programSession = nil
        model.project.masterGain = 1
        model.project.trackInputs = []
        model.project.voiceCleanup = VoiceCleanupSettings()
        model.project.coverFrame = nil
        model.selectedClipID = nil
        model.selectedMediaID = nil
        model.selectedTransitionClipID = nil
        model.selectedMarkerID = nil
        model.selectedOverlayID = nil
        model.selectedCalloutID = nil
        model.autoZoomProposals.removeAll()
        model.silenceDetectionTask?.cancel()
        model.silenceDetectionTask = nil
        model.silenceProposals = []
        model.unresolvedMedia = []
        model.undoManager.removeAllActions()
        model.coalescedCommitTask?.cancel()
        model.cancelPreviewRebuilds()
        model.beatAnalysisTask?.cancel()
        model.beatAnalysisTask = nil
        model.beatAnalyses = [:]
        model.beatAnalysisKeys = [:]
        model.showBeatMarkers = false
        model.snapToBeats = false
        model.beatOffsetSeconds = 0
        model.coalescedUndoBefore = nil
        model.coalescedUndoName = nil
        model.coalescedUndoTarget = nil
        model.audioBus.teardownLive()
        model.audioBus.teardownOffline()
        model.lastBundleFingerprints = FingerprintIndex()
        if let bundleURL = model.bundleAccessURL {
            bundleURL.stopAccessingSecurityScopedResource()
            model.bundleAccessURL = nil
        }
    }

    func adoptBundleAccess(_ bundleURL: URL, didStart: Bool, model: EditorModel) {
        guard didStart else { return }
        if let existing = model.bundleAccessURL, existing != bundleURL {
            existing.stopAccessingSecurityScopedResource()
        }
        if model.bundleAccessURL == bundleURL {
            bundleURL.stopAccessingSecurityScopedResource()
        } else {
            model.bundleAccessURL = bundleURL
        }
    }

    @discardableResult
    func open(url: URL, model: EditorModel) async -> Bool {
        let initialAccess = url.startAccessingSecurityScopedResource()
        var didTransferAccess = false
        defer {
            if initialAccess, !didTransferAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let descriptor = await Task.detached(priority: .userInitiated) {
            ProjectLocationInspector.inspect(url)
        }.value
        guard let descriptor else {
            model.statusMessage = String(localized: "Open failed: not a LocalCut project (.lcstudio or .lcbundle).")
            return false
        }
        do {
            switch descriptor.storageKind {
            case .bundle:
                let bundleURL = descriptor.url
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
                await load(document: contents.document, from: descriptor.url, bundleURL: descriptor.url,
                           storageKind: .bundle,
                           bundleAccessDidStart: initialAccess,
                           bundleFingerprints: contents.fingerprints,
                           externallyEditedAssets: mismatches,
                           model: model)
                didTransferAccess = initialAccess
            case .singleFile:
                let fileURL = descriptor.url
                let data = try await Task.detached { try Data(contentsOf: fileURL) }.value
                let document = try ProjectDocument(data: data)
                await load(document: document, from: fileURL, bundleURL: nil,
                           storageKind: .singleFile,
                           bundleFingerprints: FingerprintIndex(),
                           externallyEditedAssets: [],
                           model: model)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            model.statusMessage = EditorModel.failureStatusMessage(
                summary: "Open failed",
                detail: error.localizedDescription,
                recoverySuggestion: "Try reopening from File > Open Recent, or check that the project file hasn't been moved.")
            return false
        }
    }

    func load(document: ProjectDocument,
              from url: URL?,
              bundleURL: URL? = nil,
              storageKind: ProjectStorageKind? = nil,
              bundleAccessDidStart: Bool = false,
              bundleFingerprints: FingerprintIndex = FingerprintIndex(),
              externallyEditedAssets: [String] = [],
              model: EditorModel) async {
        releaseSession(model: model)

        model.lastBundleFingerprints = bundleFingerprints
        // Prefer the caller-supplied classification; fall back only when load
        // is used without a prior open descriptor (tests / internal paths).
        let resolvedStorageKind: ProjectStorageKind?
        if let storageKind {
            resolvedStorageKind = storageKind
        } else if bundleURL != nil {
            resolvedStorageKind = .bundle
        } else if url != nil {
            resolvedStorageKind = .singleFile
        } else {
            resolvedStorageKind = nil
        }

        if let bundleURL, bundleAccessDidStart {
            adoptBundleAccess(bundleURL, didStart: true, model: model)
        }

        model.project.name = url?.deletingPathExtension().lastPathComponent ?? document.name
        let width = max(1, document.renderWidth.isFinite ? document.renderWidth : 1920)
        let height = max(1, document.renderHeight.isFinite ? document.renderHeight : 1080)
        model.project.renderSize = CGSize(width: width, height: height)
        model.project.aspect = document.aspect
        model.project.frameRate = max(1, document.frameRate.isFinite ? document.frameRate : 30)
        EffectCompositor.purgeCaptionRasterCache()
        model.project.workingColourSpace = document.workingColourSpace
        model.project.coverFrame = document.coverFrame

        var unresolved: [MediaRef] = []
        var refreshedBookmark = false
        for ref in document.media {
            if let item = resolveMedia(ref, bundleURL: bundleURL, model: model) {
                // Treat nil and empty Data as equivalent — bundled media has
                // nil bookmark, while the decoded ref defaults to empty Data.
                let itemBookmark = item.bookmark ?? Data()
                let refBookmark = ref.bookmark
                if itemBookmark != refBookmark { refreshedBookmark = true }
                model.project.mediaItems.append(item)
            } else {
                unresolved.append(ref)
            }
        }

        model.project.videoTracks = makeTracks(from: document.videoTracks, kind: .video, fallbackName: "V1")
        model.project.audioTracks = makeTracks(from: document.audioTracks, kind: .audio, fallbackName: "A1")
        model.project.captionTracks = document.captionTracks.map { $0.makeTrack() }
        model.project.markers = document.markers.sorted { $0.time < $1.time }
        model.project.masterGain = document.audioBus.masterGain
        model.project.trackInputs = document.audioBus.trackInputs.map(\.trackInput)
        model.project.voiceCleanup = document.audioBus.voiceCleanup

        // Load overlays from the document.
        model.project.overlays = document.overlays.map { $0.makeOverlayClip() }
        model.project.overlayBookmarks = [:]
        model.project.overlayBundlePaths = [:]
        for doc in document.overlays {
            model.project.overlayBookmarks[doc.id] = doc.bookmark
            if let path = doc.bundleRelativePath,
               ProjectBundleLayout.isSafeAssetRelativePath(path) {
                model.project.overlayBundlePaths[doc.id] = path
            }
        }

        // Load callouts and padded background (Phase 43).
        model.project.callouts = document.callouts
        model.project.paddedBackground = PaddedBackgroundBundleResolver.resolve(
            document.paddedBackground,
            bundleURL: bundleURL)
        model.project.screencastEventLogs = document.screencastEventLogs.filter(\.isSupportedSchema)
        if let log = model.project.screencastEventLogs.last {
            model.autoZoomProposals = AutoZoomProposalGenerator.generateProposals(
                from: log,
                canvasSize: model.project.renderSize)
        } else {
            model.autoZoomProposals.removeAll()
        }
        model.project.keystrokeOverlayClips = document.keystrokeOverlayClips
        // Phase 45: scene doc is migrated on decode (in ProjectDocument.init(from:)).
        model.project.sceneDoc = document.sceneDoc
        model.project.layoutTracks = document.layoutTracks.map {
            let track = LayoutTrack(id: $0.id, name: $0.name)
            track.isMuted = $0.isMuted
            track.clips = $0.clips
            return track
        }

        let isNewerSchema = document.schemaVersion > ProjectDocument.currentSchemaVersion
        if !isNewerSchema, let url, let resolvedStorageKind {
            model.projectSessionLocation = .saved(
                url: url,
                storageKind: resolvedStorageKind)
        } else {
            model.projectSessionLocation = .unsaved
        }
        model.unresolvedMedia = unresolved
        model.isDirty = isNewerSchema || refreshedBookmark
        if let url, !isNewerSchema {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        model.undoManager.removeAllActions()
        model.refreshUndoFlags()

        await model.rebuild()
        for item in model.project.mediaItems {
            Task { await item.loadThumbnail() }
        }
        model.loadAvailableBeatCaches()

        var notes: [String] = []
        if isNewerSchema { notes.append("saved in a newer format — saving downconverts to this version") }
        if refreshedBookmark { notes.append("media moved — save to update its location") }
        if !unresolved.isEmpty { notes.append("\(unresolved.count) media file(s) need relinking") }
        if !externallyEditedAssets.isEmpty {
            notes.append("\(externallyEditedAssets.count) bundled asset(s) changed externally — re-import or accept on next save")
        }
        notes.append(contentsOf: await lottieOverlayWarnings(model: model))
        model.statusMessage = notes.isEmpty
            ? "Opened \(model.project.name)."
            : "Opened \(model.project.name) — " + notes.joined(separator: "; ") + "."
    }

    func relinkNextMissingMedia(model: EditorModel) async {
        guard let ref = model.unresolvedMedia.first else { return }

        let panel = NSOpenPanel()
        panel.message = "Locate “\(ref.displayName)”."
        panel.prompt = "Relink"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let generation = model.sessionGeneration
        let access = url.startAccessingSecurityScopedResource()
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            if access { url.stopAccessingSecurityScopedResource() }
            model.statusMessage = "Could not access \(url.lastPathComponent)."
            return
        }

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
            model.statusMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        guard model.sessionGeneration == generation else {
            if access { url.stopAccessingSecurityScopedResource() }
            return
        }
        retainAccess(url, didStart: access, model: model)
        item.bookmark = bookmark

        model.performUndoable("Relink Media") {
            model.project.mediaItems.append(item)
            model.unresolvedMedia.removeAll { $0.id == ref.id }
        }

        let mismatched = (ref.hasVideo && !item.hasVideo) || (ref.hasAudio && !item.hasAudio)
        if mismatched {
            model.statusMessage = "Relinked \(item.name), but its tracks differ from the original — some clips may not render."
        } else {
            model.statusMessage = model.unresolvedMedia.isEmpty
                ? "Relinked \(item.name)."
                : "Relinked \(item.name) — \(model.unresolvedMedia.count) remaining."
        }
        await model.rebuild()
        await item.loadThumbnail()
    }

    func retainAccess(_ url: URL, didStart: Bool, model: EditorModel) {
        guard didStart else { return }
        if model.accessedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
        } else {
            model.accessedURLs.insert(url)
        }
    }

    private func makeTracks(from docs: [TrackDoc], kind: TrackKind, fallbackName: String) -> [Track] {
        guard !docs.isEmpty else { return [Track(name: fallbackName, kind: kind)] }
        return docs.map { doc in
            let track = Track(id: doc.id, name: doc.name.isEmpty ? fallbackName : doc.name, kind: kind)
            track.isMuted = doc.isMuted
            track.clips = doc.clips.map { $0.makeClip() }
            return track
        }
    }

    private func resolveMedia(_ ref: MediaRef, bundleURL: URL?, model: EditorModel) -> MediaItem? {
        if let relative = ref.bundleRelativePath, let bundleURL {
            guard ProjectBundleLayout.isSafeAssetRelativePath(relative) else {
                return ref.bookmark.isEmpty ? nil : resolveMediaViaBookmark(ref, model: model)
            }
            let fileURL = bundleURL.appendingPathComponent(relative)
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                return ref.bookmark.isEmpty ? nil : resolveMediaViaBookmark(ref, model: model)
            }
            let item = MediaItem(url: fileURL, id: ref.id)
            populate(item: item, from: ref)
            item.bundleRelativePath = relative
            item.bookmark = nil
            return item
        }
        return resolveMediaViaBookmark(ref, model: model)
    }

    private func resolveMediaViaBookmark(_ ref: MediaRef, model: EditorModel) -> MediaItem? {
        guard !ref.bookmark.isEmpty else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: ref.bookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        guard access || FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        retainAccess(url, didStart: access, model: model)

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
        item.captureSourceID = ref.captureSourceID
    }

    private func lottieOverlayWarnings(model: EditorModel) async -> [String] {
        let entries = model.project.overlays.compactMap { overlay -> (String, URL)? in
            guard overlay.sourceType == .lottie,
                  let url = model.resolveOverlayURL(for: overlay) else {
                return nil
            }
            return (String(overlay.id.uuidString.prefix(8)), url)
        }
        var warnings: [String] = []
        for (id, url) in entries {
            guard let warning = await LottieFrameSource.unsupportedFeatureWarningAsync(for: url) else { continue }
            warnings.append("Lottie overlay \(id) \(warning)")
        }
        return warnings
    }

}
