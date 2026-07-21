import Foundation
import AppKit
import LocalCutCore

@MainActor
extension DocumentController {
    func save(model: EditorModel) async {
        guard case .saved(let url, let storageKind) = model.projectSessionLocation else { return }
        await write(to: url, storageKind: storageKind, model: model)
    }

    func saveAs(url: URL, model: EditorModel) async {
        guard let kind = storageKindForWrite(to: url, model: model, isSaveAs: true) else {
            model.statusMessage = String(localized: "Save failed: choose a LocalCut project (.lcstudio or .lcbundle).")
            return
        }
        await write(to: url, storageKind: kind, model: model)
    }

    func writeSynchronously(to url: URL, model: EditorModel) -> Bool {
        guard let kind = storageKindForWrite(to: url, model: model, isSaveAs: model.documentURL == nil) else {
            model.statusMessage = String(localized: "Save failed: choose a LocalCut project (.lcstudio or .lcbundle).")
            return false
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let originalPaths = model.project.mediaItems.map { ($0, $0.bundleRelativePath) }
        let originalOverlayPaths = model.project.overlayBundlePaths
        let originalPaddedBackground = model.project.paddedBackground
        var overlayAccesses: [URL] = []
        defer { stopOverlayAccesses(overlayAccesses) }
        do {
            if kind == .bundle {
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
                let backgroundPlan = PaddedBackgroundBundleResolver.bundledAssetPlan(model: model)
                overlayAccesses.append(contentsOf: backgroundPlan.accessedURLs)
                let projectJSON = try encodedDocument(forBundle: true, model: model)
                let makeOtioData = makeOtioDataGenerator(forBundle: true, model: model)
                let index = try ProjectBundle.write(projectJSON: projectJSON,
                                                     to: url,
                                                     bundledMedia: bundledMedia + overlayPlan.assets + backgroundPlan.assets,
                                                     previousFingerprints: model.lastBundleFingerprints)
                let otioOk = writeProjectOtio(makeOtioData(index), to: url)
                model.lastBundleFingerprints = index
                model.persistBeatCachesSynchronously(to: url)
                model.statusMessage = otioOk
                    ? "Saved \(url.lastPathComponent)."
                    : "Saved \(url.lastPathComponent) — OTIO sidecar write failed."
            } else {
                let document = makeDocumentForSave(forBundle: false, model: model)
                let data = try document.encoded()
                try data.write(to: url, options: .atomic)
                adoptSingleFileOverlayBookmarks(from: document.overlays, model: model)
                PaddedBackgroundBundleResolver.adoptSingleFileBookmark(from: document.paddedBackground, model: model)
                model.statusMessage = "Saved \(url.lastPathComponent)."
            }
            adoptSaved(url: url, storageKind: kind, model: model)
            return true
        } catch {
            for (item, path) in originalPaths {
                item.bundleRelativePath = path
            }
            model.project.overlayBundlePaths = originalOverlayPaths
            model.project.paddedBackground = originalPaddedBackground
            model.statusMessage = EditorModel.failureStatusMessage(
                summary: "Save failed",
                detail: error.localizedDescription,
                recoverySuggestion: "Check available disk space and try Save As to a different location.")
            return false
        }
    }

    /// Resolves the storage kind for a write without re-sniffing disk contents.
    /// In-place Save uses the session's stored kind; Save As uses the panel
    /// destination's explicit representation (extension / content type).
    private func storageKindForWrite(
        to url: URL,
        model: EditorModel,
        isSaveAs: Bool = false
    ) -> ProjectStorageKind? {
        let standardized = url.standardizedFileURL
        if !isSaveAs,
           case .saved(let sessionURL, let storageKind) = model.projectSessionLocation,
           sessionURL.standardizedFileURL == standardized {
            return storageKind
        }
        if let kind = ProjectLocationInspector.storageKindForSaveDestination(url: url) {
            return kind
        }
        // Extensionless in-place save of a previously validated bundle only.
        if case .saved(let sessionURL, .bundle) = model.projectSessionLocation,
           sessionURL.standardizedFileURL == standardized {
            return .bundle
        }
        return nil
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
            if var background = document.paddedBackground {
                if background.imageBookmark == nil,
                   let bookmark = PaddedBackgroundBundleResolver.singleFileBookmark(for: background, model: model) {
                    background.imageBookmark = bookmark
                }
                background.imageBundleRelativePath = nil
                document.paddedBackground = background
            }
        } else {
            document.overlays = document.overlays.map { overlay in
                var copy = overlay
                if copy.bundleRelativePath != nil {
                    copy.bookmark = Data()
                }
                return copy
            }
            if var background = document.paddedBackground {
                if let path = background.imageBundleRelativePath,
                   ProjectBundleLayout.isSafeAssetRelativePath(path) {
                    background.imageBookmark = nil
                } else if background.imageBundleRelativePath != nil {
                    background.imageBundleRelativePath = nil
                }
                document.paddedBackground = background
            }
            if let path = document.coverFrame?.bundleRelativePath,
               !ProjectBundleLayout.isSafeCoversPath(path) {
                document.coverFrame?.bundleRelativePath = nil
            }
        }
        document.media.append(contentsOf: model.unresolvedMedia)
        return document
    }

    func canConvertToBundle(model: EditorModel) -> Bool {
        guard case .saved(_, .singleFile) = model.projectSessionLocation else { return false }
        return true
    }

    func convertToBundle(to bundleURL: URL, model: EditorModel) async {
        await writeBundlePackage(to: bundleURL, model: model, intent: .convertFromSingleFile)
    }

    private func write(to url: URL, storageKind: ProjectStorageKind, model: EditorModel) async {
        switch storageKind {
        case .bundle:
            await writeBundlePackage(to: url, model: model, intent: .save)
        case .singleFile:
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
            PaddedBackgroundBundleResolver.adoptSingleFileBookmark(from: document.paddedBackground, model: model)
            adoptSaved(url: url, storageKind: .singleFile, cleanIfRevision: savedRevision, model: model)
            model.statusMessage = "Saved \(url.lastPathComponent)."
        } catch is CancellationError {
            return
        } catch {
            model.statusMessage = EditorModel.failureStatusMessage(
                summary: "Save failed",
                detail: error.localizedDescription,
                recoverySuggestion: "Check available disk space and try Save As to a different location.")
        }
    }

    /// Shared async package write for Save-as-bundle and Convert-to-bundle.
    /// Differences are confined to media selection and post-success policy.
    private enum BundleWriteIntent {
        case save
        case convertFromSingleFile
    }

    private struct BundlePathSnapshot {
        let mediaPaths: [(MediaItem, String?)]
        let overlayPaths: [UUID: String]
        let coverPath: String?
        let paddedBackground: PaddedBackgroundPreset?

        static func capture(from model: EditorModel) -> BundlePathSnapshot {
            BundlePathSnapshot(
                mediaPaths: model.project.mediaItems.map { ($0, $0.bundleRelativePath) },
                overlayPaths: model.project.overlayBundlePaths,
                coverPath: model.project.coverFrame?.bundleRelativePath,
                paddedBackground: model.project.paddedBackground)
        }

        func restore(into model: EditorModel) {
            for (item, path) in mediaPaths {
                item.bundleRelativePath = path
            }
            model.project.overlayBundlePaths = overlayPaths
            model.project.coverFrame?.bundleRelativePath = coverPath
            model.project.paddedBackground = paddedBackground
        }
    }

    private func writeBundlePackage(
        to bundleURL: URL,
        model: EditorModel,
        intent: BundleWriteIntent
    ) async {
        let scoped = bundleURL.startAccessingSecurityScopedResource()
        var didTransferAccess = false
        defer {
            if scoped, !didTransferAccess {
                bundleURL.stopAccessingSecurityScopedResource()
            }
        }
        let snapshot = BundlePathSnapshot.capture(from: model)
        var overlayAccesses: [URL] = []
        defer { stopOverlayAccesses(overlayAccesses) }
        do {
            let savedRevision = model.mutationRevision
            let bundledMedia = prepareBundledMedia(for: intent, model: model)
            let overlayPlan = bundledOverlays(model: model)
            overlayAccesses.append(contentsOf: overlayPlan.accessedURLs)
            let backgroundPlan = PaddedBackgroundBundleResolver.bundledAssetPlan(model: model)
            overlayAccesses.append(contentsOf: backgroundPlan.accessedURLs)
            let coverPreparation = await model.makeCoverBundleData()
            if let coverData = coverPreparation.data {
                model.project.coverFrame?.bundleRelativePath =
                    ProjectBundleLayout.coverRelativePath(format: coverData.fileExtension)
            } else if model.project.coverFrame != nil {
                model.project.coverFrame?.bundleRelativePath = nil
            }
            let projectJSON = try encodedDocument(forBundle: true, model: model)
            let makeOtioData = makeOtioDataGenerator(forBundle: true, model: model)
            let previous = model.lastBundleFingerprints
            let bundleURLCopy = bundleURL
            let index = try await Task.detached {
                try ProjectBundle.write(projectJSON: projectJSON, to: bundleURLCopy,
                                        bundledMedia: bundledMedia + overlayPlan.assets + backgroundPlan.assets,
                                        previousFingerprints: previous,
                                        coverData: coverPreparation.data)
            }.value
            let otioOk = writeProjectOtio(makeOtioData(index), to: bundleURL)
            model.lastBundleFingerprints = index

            replaceMediaItemsForBundle(at: bundleURL, model: model)
            await model.persistBeatCaches(to: bundleURL)
            adoptBundleAccess(bundleURL, didStart: scoped, model: model)
            didTransferAccess = scoped

            switch intent {
            case .save:
                adoptSaved(url: bundleURL, storageKind: .bundle, cleanIfRevision: savedRevision, model: model)
            case .convertFromSingleFile:
                adoptSaved(url: bundleURL, storageKind: .bundle, model: model)
                await model.rebuild()
            }

            var notes: [String] = []
            if let coverWarning = coverPreparation.warning { notes.append(coverWarning) }
            if !otioOk { notes.append("OTIO sidecar write failed") }
            switch intent {
            case .save:
                model.statusMessage = notes.isEmpty
                    ? "Saved \(bundleURL.lastPathComponent)."
                    : "Saved \(bundleURL.lastPathComponent); \(notes.joined(separator: "; "))"
            case .convertFromSingleFile:
                model.statusMessage = notes.isEmpty
                    ? "Converted to bundle — original .lcstudio left in place."
                    : "Converted to bundle — original .lcstudio left in place; \(notes.joined(separator: "; "))"
            }
        } catch is CancellationError {
            snapshot.restore(into: model)
        } catch {
            snapshot.restore(into: model)
            switch intent {
            case .save:
                model.statusMessage = EditorModel.failureStatusMessage(
                    summary: "Save failed",
                    detail: error.localizedDescription,
                    recoverySuggestion: "Check available disk space and try Save As to a different location.")
            case .convertFromSingleFile:
                model.statusMessage = "Convert failed: \(error.localizedDescription)"
            }
        }
    }

    private func prepareBundledMedia(
        for intent: BundleWriteIntent,
        model: EditorModel
    ) -> [ProjectBundle.BundledMedia] {
        model.project.mediaItems.compactMap { item in
            switch intent {
            case .save:
                guard let relative = bundleRelativePath(for: item, model: model) else { return nil }
                item.bundleRelativePath = relative
                return ProjectBundle.BundledMedia(
                    mediaID: item.id,
                    sourceURL: item.url,
                    bundleRelativePath: relative)
            case .convertFromSingleFile:
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
        }
    }

    private func encodedDocument(forBundle: Bool, model: EditorModel) throws -> Data {
        try makeDocumentForSave(forBundle: forBundle, model: model).encoded()
    }

    /// Builds an OTIO generator from a main-actor document snapshot.
    /// Bundle saves call it after copying media so the fresh SHA-256 index can
    /// be embedded in `ExternalReference.metadata.localcut.fingerprint`.
    private func makeOtioDataGenerator(forBundle: Bool,
                                       model: EditorModel) -> @MainActor (FingerprintIndex) -> Data? {
        let document = makeDocumentForSave(forBundle: forBundle, model: model)
        let mediaPaths: [UUID: (name: String, bundleRelativePath: String?, urlPath: String)] = Dictionary(
            model.project.mediaItems.map {
                ($0.id, (name: $0.url.lastPathComponent,
                         bundleRelativePath: $0.bundleRelativePath,
                         urlPath: $0.url.path))
            },
            uniquingKeysWith: { first, _ in first })
        return { fingerprints in
            let options = OtioSerializationOptions(
                bundleMode: forBundle,
                resolveTargetUrl: { mediaID in
                    if let info = mediaPaths[mediaID] {
                        if forBundle, let relative = info.bundleRelativePath {
                            return relative
                        }
                        // For unbundled media in bundle mode, use the original
                        // file path so foreign tools can relink. In standalone
                        // mode the display filename suffices.
                        return forBundle ? info.urlPath : info.name
                    } else {
                        return mediaID.uuidString
                    }
                },
                resolveFingerprint: { mediaID in
                    guard forBundle,
                          let relative = mediaPaths[mediaID]?.bundleRelativePath else {
                        return nil
                    }
                    return fingerprints.entries[relative]
                },
                isMediaResolved: { mediaID in
                    mediaPaths[mediaID] != nil
                })
            let (json, warnings) = serializeTimelineToOtio(document, options: options)
            guard !warnings.contains(where: { $0.kind == .serializationFailure }) else {
                return nil
            }
            #if DEBUG
            guard validateOtioDocument(json).isEmpty else { return nil }
            #endif
            return json.data(using: .utf8)
        }
    }

    /// Writes the OTIO sidecar to the bundle. Returns `true` on success,
    /// `false` if serialization produced no data or the write/cleanup failed
    /// (non-fatal; bundle export still succeeds). When `data` is `nil`,
    /// removes any stale sidecar.
    /// - Visibility: `internal` so tests can verify cleanup behavior.
    @discardableResult
    func writeProjectOtio(_ data: Data?, to bundleURL: URL) -> Bool {
        let otioURL = bundleURL.appendingPathComponent(ProjectBundleLayout.projectOTIO)
        guard let data else {
            // Serialization failed or produced no data — remove stale sidecar.
            guard FileManager.default.fileExists(atPath: otioURL.path) else { return false }
            do {
                try FileManager.default.removeItem(at: otioURL)
            } catch {
                // A stale sidecar may persist. Log but don't block the save.
                return false
            }
            return false
        }
        do {
            try data.write(to: otioURL, options: .atomic)
            return true
        } catch {
            try? FileManager.default.removeItem(at: otioURL)
            return false
        }
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
              case .saved(let bundleURL, .bundle) = model.projectSessionLocation else {
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

    private func adoptSaved(
        url: URL,
        storageKind: ProjectStorageKind,
        cleanIfRevision revision: Int? = nil,
        model: EditorModel
    ) {
        model.projectSessionLocation = .saved(url: url, storageKind: storageKind)
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
