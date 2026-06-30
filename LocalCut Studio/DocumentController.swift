import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import LocalCutCore

@MainActor
final class DocumentController {
    func newDocument(model: EditorModel) {
        releaseSession(model: model)
        model.project.name = "Untitled"
        model.project.aspect = .widescreen16x9
        model.project.renderSize = CGSize(width: 1920, height: 1080)
        model.project.frameRate = 30
        model.project.workingColourSpace = .sRGB
        model.project.videoTracks = [Track(name: "V1", kind: .video)]
        model.project.audioTracks = [Track(name: "A1", kind: .audio)]
        model.project.captionTracks = []
        model.project.markers = []
        model.project.overlays = []
        model.project.overlayBookmarks = [:]
        model.project.overlayBundlePaths = [:]
        model.project.masterGain = 1
        model.project.trackInputs = []
        model.project.voiceCleanup = VoiceCleanupSettings()
        model.beatAnalyses = [:]
        model.beatAnalysisKeys = [:]
        model.showBeatMarkers = false
        model.snapToBeats = false
        model.beatOffsetSeconds = 0
        model.project.coverFrame = nil
        model.documentURL = nil
        model.isDirty = false
        model.unresolvedMedia = []
        model.totalDuration = 0
        model.currentTime = 0
        model.replacePreviewItem(with: nil)
        model.refreshUndoFlags()
        model.statusMessage = "New project."
    }

    func releaseSession(model: EditorModel) {
        model.sessionGeneration &+= 1
        model.player.pause()
        model.isPlaying = false
        model.replacePreviewItem(with: nil)
        for url in model.accessedURLs { url.stopAccessingSecurityScopedResource() }
        model.accessedURLs.removeAll()
        RenderCache.shared.purge()
        model.project.mediaItems.removeAll()
        model.project.captionTracks.removeAll()
        model.project.markers.removeAll()
        model.project.overlays.removeAll()
        model.project.overlayBookmarks.removeAll()
        model.project.overlayBundlePaths.removeAll()
        model.project.masterGain = 1
        model.project.trackInputs = []
        model.project.voiceCleanup = VoiceCleanupSettings()
        model.project.coverFrame = nil
        model.selectedClipID = nil
        model.selectedMediaID = nil
        model.selectedTransitionClipID = nil
        model.selectedMarkerID = nil
        model.selectedOverlayID = nil
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

    func open(url: URL, model: EditorModel) async {
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
                await load(document: contents.document, from: url, bundleURL: url,
                           bundleAccessDidStart: initialAccess,
                           bundleFingerprints: contents.fingerprints,
                           externallyEditedAssets: mismatches,
                           model: model)
                didTransferAccess = initialAccess
            } else {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                let document = try ProjectDocument(data: data)
                await load(document: document, from: url, bundleURL: nil,
                           bundleFingerprints: FingerprintIndex(),
                           externallyEditedAssets: [],
                           model: model)
            }
        } catch {
            model.statusMessage = "Open failed: \(error.localizedDescription)"
        }
    }

    func load(document: ProjectDocument,
              from url: URL?,
              bundleURL: URL? = nil,
              bundleAccessDidStart: Bool = false,
              bundleFingerprints: FingerprintIndex = FingerprintIndex(),
              externallyEditedAssets: [String] = [],
              model: EditorModel) async {
        releaseSession(model: model)

        model.lastBundleFingerprints = bundleFingerprints

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
        model.project.paddedBackground = document.paddedBackground

        let isNewerSchema = document.schemaVersion > ProjectDocument.currentSchemaVersion
        model.documentURL = isNewerSchema ? nil : url
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

    func save(model: EditorModel) async {
        guard let url = model.documentURL else { return }
        await write(to: url, model: model)
    }

    func saveAs(url: URL, model: EditorModel) async {
        await write(to: url, model: model)
    }

    func writeSynchronously(to url: URL, model: EditorModel) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let originalPaths = model.project.mediaItems.map { ($0, $0.bundleRelativePath) }
        let originalOverlayPaths = model.project.overlayBundlePaths
        var overlayAccesses: [URL] = []
        defer { stopOverlayAccesses(overlayAccesses) }
        do {
            if url.pathExtension == ProjectBundleLayout.fileExtension {
                guard model.project.coverFrame == nil else {
                    model.statusMessage = "Save failed: bundle cover generation requires the async Save path."
                    return false
                }
                let bundledMedia: [ProjectBundle.BundledMedia] = model.project.mediaItems.compactMap { item in
                    guard let relative = bundleRelativePath(for: item, model: model) else { return nil }
                    item.bundleRelativePath = relative
                    return ProjectBundle.BundledMedia(
                        mediaID: item.id,
                        sourceURL: item.url,
                        bundleRelativePath: relative)
                }
                let overlayPlan = bundledOverlays(model: model)
                overlayAccesses.append(contentsOf: overlayPlan.accessedURLs)
                let projectJSON = try encodedDocument(forBundle: true, model: model)
                let index = try ProjectBundle.write(projectJSON: projectJSON,
                                                     to: url,
                                                     bundledMedia: bundledMedia + overlayPlan.assets,
                                                     previousFingerprints: model.lastBundleFingerprints)
                model.lastBundleFingerprints = index
                model.persistBeatCachesSynchronously(to: url)
            } else {
                let document = makeDocumentForSave(forBundle: false, model: model)
                let data = try document.encoded()
                try data.write(to: url, options: .atomic)
                adoptSingleFileOverlayBookmarks(from: document.overlays, model: model)
            }
            adoptSaved(url: url, model: model)
            model.statusMessage = "Saved \(url.lastPathComponent)."
            return true
        } catch {
            for (item, path) in originalPaths {
                item.bundleRelativePath = path
            }
            model.project.overlayBundlePaths = originalOverlayPaths
            model.statusMessage = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func makeDocumentForSave(forBundle: Bool = false, model: EditorModel) -> ProjectDocument {
        ensureBookmarks(forBundle: forBundle, model: model)
        var document = ProjectDocument(project: model.project)
        document.schemaVersion = forBundle
            ? ProjectDocument.currentSchemaVersion
            : ProjectDocument.singleFileSchemaVersion
        document.bundleFormat = forBundle ? ProjectDocument.currentBundleFormat : nil
        if !forBundle {
            document.coverFrame?.bundleRelativePath = nil
            document.media = document.media.map { ref in
                var copy = ref
                copy.bundleRelativePath = nil
                return copy
            }
            document.overlays = document.overlays.map { overlay in
                var copy = overlay
                if copy.bookmark.isEmpty,
                   let bookmark = singleFileOverlayBookmark(for: copy, model: model) {
                    copy.bookmark = bookmark
                }
                copy.bundleRelativePath = nil
                return copy
            }
        } else {
            document.overlays = document.overlays.map { overlay in
                var copy = overlay
                if copy.bundleRelativePath != nil {
                    copy.bookmark = Data()
                }
                return copy
            }
            if let path = document.coverFrame?.bundleRelativePath,
               !ProjectBundleLayout.isSafeCoversPath(path) {
                document.coverFrame?.bundleRelativePath = nil
            }
        }
        document.media.append(contentsOf: model.unresolvedMedia)
        return document
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

    func canConvertToBundle(model: EditorModel) -> Bool {
        guard let url = model.documentURL else { return false }
        return url.pathExtension == ProjectDocument.fileExtension
    }

    func convertToBundle(to bundleURL: URL, model: EditorModel) async {
        let scoped = bundleURL.startAccessingSecurityScopedResource()
        var didTransferAccess = false
        defer {
            if scoped, !didTransferAccess {
                bundleURL.stopAccessingSecurityScopedResource()
            }
        }
        let originalPaths = model.project.mediaItems.map { ($0, $0.bundleRelativePath) }
        let originalOverlayPaths = model.project.overlayBundlePaths
        let originalCoverPath = model.project.coverFrame?.bundleRelativePath
        var overlayAccesses: [URL] = []
        defer { stopOverlayAccesses(overlayAccesses) }
        do {
            let bundledMedia: [ProjectBundle.BundledMedia] = model.project.mediaItems.compactMap { item in
                guard item.wantsBundling else {
                    item.bundleRelativePath = nil
                    return nil
                }
                let relative = ProjectBundleLayout.assetRelativePath(
                    mediaID: item.id, sourceExtension: item.url.pathExtension)
                item.bundleRelativePath = relative
                return ProjectBundle.BundledMedia(
                    mediaID: item.id,
                    sourceURL: item.url,
                    bundleRelativePath: relative)
            }
            let overlayPlan = bundledOverlays(model: model)
            overlayAccesses.append(contentsOf: overlayPlan.accessedURLs)
            let coverPreparation = await model.makeCoverBundleData()
            if let coverData = coverPreparation.data {
                model.project.coverFrame?.bundleRelativePath =
                    ProjectBundleLayout.coverRelativePath(format: coverData.fileExtension)
            } else if model.project.coverFrame != nil {
                model.project.coverFrame?.bundleRelativePath = nil
            }
            let projectJSON = try encodedDocument(forBundle: true, model: model)
            let bundleURLCopy = bundleURL
            let previous = model.lastBundleFingerprints
            let index = try await Task.detached {
                try ProjectBundle.write(projectJSON: projectJSON, to: bundleURLCopy,
                                        bundledMedia: bundledMedia + overlayPlan.assets,
                                        previousFingerprints: previous,
                                        coverData: coverPreparation.data)
            }.value
            model.lastBundleFingerprints = index

            replaceMediaItemsForBundle(at: bundleURL, model: model)
            await model.persistBeatCaches(to: bundleURL)
            adoptBundleAccess(bundleURL, didStart: scoped, model: model)
            didTransferAccess = scoped

            adoptSaved(url: bundleURL, model: model)
            await model.rebuild()
            model.statusMessage = coverPreparation.warning.map {
                "Converted to bundle — original .lcstudio left in place; \($0)"
            } ?? "Converted to bundle — original .lcstudio left in place."
        } catch {
            for (item, path) in originalPaths {
                item.bundleRelativePath = path
            }
            model.project.overlayBundlePaths = originalOverlayPaths
            model.project.coverFrame?.bundleRelativePath = originalCoverPath
            model.statusMessage = "Convert failed: \(error.localizedDescription)"
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
    }

    private func write(to url: URL, model: EditorModel) async {
        if url.pathExtension == ProjectBundleLayout.fileExtension {
            await writeBundle(to: url, model: model)
        } else {
            await writeSingleFile(to: url, model: model)
        }
    }

    private func writeSingleFile(to url: URL, model: EditorModel) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let savedRevision = model.mutationRevision
            let document = makeDocumentForSave(forBundle: false, model: model)
            let data = try document.encoded()
            try await Task.detached { try data.write(to: url, options: .atomic) }.value
            adoptSingleFileOverlayBookmarks(from: document.overlays, model: model)
            adoptSaved(url: url, cleanIfRevision: savedRevision, model: model)
            model.statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            model.statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func writeBundle(to bundleURL: URL, model: EditorModel) async {
        let scoped = bundleURL.startAccessingSecurityScopedResource()
        var didTransferAccess = false
        defer {
            if scoped, !didTransferAccess {
                bundleURL.stopAccessingSecurityScopedResource()
            }
        }
        let originalPaths = model.project.mediaItems.map { ($0, $0.bundleRelativePath) }
        let originalOverlayPaths = model.project.overlayBundlePaths
        let originalCoverPath = model.project.coverFrame?.bundleRelativePath
        var overlayAccesses: [URL] = []
        defer { stopOverlayAccesses(overlayAccesses) }
        do {
            let savedRevision = model.mutationRevision
            let bundledMedia: [ProjectBundle.BundledMedia] = model.project.mediaItems.compactMap { item in
                let relative = bundleRelativePath(for: item, model: model)
                guard let relative else { return nil }
                item.bundleRelativePath = relative
                return ProjectBundle.BundledMedia(
                    mediaID: item.id,
                    sourceURL: item.url,
                    bundleRelativePath: relative)
            }
            let overlayPlan = bundledOverlays(model: model)
            overlayAccesses.append(contentsOf: overlayPlan.accessedURLs)
            let coverPreparation = await model.makeCoverBundleData()
            if let coverData = coverPreparation.data {
                model.project.coverFrame?.bundleRelativePath =
                    ProjectBundleLayout.coverRelativePath(format: coverData.fileExtension)
            } else if model.project.coverFrame != nil {
                model.project.coverFrame?.bundleRelativePath = nil
            }
            let projectJSON = try encodedDocument(forBundle: true, model: model)
            let previous = model.lastBundleFingerprints
            let bundleURLCopy = bundleURL
            let index = try await Task.detached {
                try ProjectBundle.write(projectJSON: projectJSON, to: bundleURLCopy,
                                        bundledMedia: bundledMedia + overlayPlan.assets,
                                        previousFingerprints: previous,
                                        coverData: coverPreparation.data)
            }.value
            model.lastBundleFingerprints = index

            replaceMediaItemsForBundle(at: bundleURL, model: model)
            await model.persistBeatCaches(to: bundleURL)
            adoptBundleAccess(bundleURL, didStart: scoped, model: model)
            didTransferAccess = scoped

            adoptSaved(url: bundleURL, cleanIfRevision: savedRevision, model: model)
            model.statusMessage = coverPreparation.warning.map {
                "Saved \(bundleURL.lastPathComponent); \($0)"
            } ?? "Saved \(bundleURL.lastPathComponent)."
        } catch {
            for (item, path) in originalPaths {
                item.bundleRelativePath = path
            }
            model.project.overlayBundlePaths = originalOverlayPaths
            model.project.coverFrame?.bundleRelativePath = originalCoverPath
            model.statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func encodedDocument(forBundle: Bool, model: EditorModel) throws -> Data {
        try makeDocumentForSave(forBundle: forBundle, model: model).encoded()
    }

    private func bundleRelativePath(for item: MediaItem, model: EditorModel) -> String? {
        guard item.wantsBundling else { return nil }
        if let existing = item.bundleRelativePath { return existing }
        return ProjectBundleLayout.assetRelativePath(mediaID: item.id, sourceExtension: item.url.pathExtension)
    }

    private struct OverlayBundlePlan {
        var assets: [ProjectBundle.BundledMedia] = []
        var accessedURLs: [URL] = []
    }

    private func bundledOverlays(model: EditorModel) -> OverlayBundlePlan {
        var plan = OverlayBundlePlan()
        for overlay in model.project.overlays {
            guard let sourceURL = model.resolveOverlayURL(for: overlay) else { continue }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            if didAccess { plan.accessedURLs.append(sourceURL) }
            let relative = overlayBundleRelativePath(for: overlay, sourceURL: sourceURL, model: model)
            model.project.overlayBundlePaths[overlay.id] = relative
            plan.assets.append(ProjectBundle.BundledMedia(
                mediaID: overlay.id,
                sourceURL: sourceURL,
                bundleRelativePath: relative))
        }
        return plan
    }

    private func overlayBundleRelativePath(for overlay: OverlayClip,
                                           sourceURL: URL,
                                           model: EditorModel) -> String {
        if let existing = model.project.overlayBundlePaths[overlay.id],
           ProjectBundleLayout.isSafeAssetRelativePath(existing) {
            return existing
        }
        return ProjectBundleLayout.assetRelativePath(mediaID: overlay.id,
                                                     sourceExtension: sourceURL.pathExtension)
    }

    private func stopOverlayAccesses(_ urls: [URL]) {
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func singleFileOverlayBookmark(for overlay: OverlayClipDoc, model: EditorModel) -> Data? {
        guard let relativePath = overlay.bundleRelativePath,
              ProjectBundleLayout.isSafeAssetRelativePath(relativePath),
              let bundleURL = model.documentURL,
              ProjectBundle.isBundle(url: bundleURL) else {
            return nil
        }
        let didAccess = bundleURL.startAccessingSecurityScopedResource()
        defer { if didAccess { bundleURL.stopAccessingSecurityScopedResource() } }
        let sourceURL = bundleURL.appendingPathComponent(relativePath)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else { return nil }
        return try? sourceURL.bookmarkData(options: .withSecurityScope,
                                           includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
    }

    private func adoptSingleFileOverlayBookmarks(from overlays: [OverlayClipDoc], model: EditorModel) {
        for overlay in overlays where !overlay.bookmark.isEmpty {
            model.project.overlayBookmarks[overlay.id] = overlay.bookmark
            model.project.overlayBundlePaths.removeValue(forKey: overlay.id)
        }
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

    private func adoptSaved(url: URL, cleanIfRevision revision: Int? = nil, model: EditorModel) {
        model.documentURL = url
        model.project.name = url.deletingPathExtension().lastPathComponent
        if revision == nil || revision == model.mutationRevision { model.isDirty = false }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func ensureBookmarks(forBundle: Bool = false, model: EditorModel) {
        for item in model.project.mediaItems where item.bookmark == nil {
            if forBundle && item.bundleRelativePath != nil { continue }
            item.bookmark = try? item.url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil)
        }
    }

    private func replaceMediaItemsForBundle(at bundleURL: URL, model: EditorModel) {
        model.project.mediaItems = model.project.mediaItems.map { item in
            guard let relative = item.bundleRelativePath else { return item }
            let bundled = bundleURL.appendingPathComponent(relative)
            if item.url.standardizedFileURL == bundled.standardizedFileURL {
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
            replacement.bookmark = nil
            return replacement
        }
    }
}
