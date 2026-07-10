import Foundation
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers
import LocalCutCore

extension UTType {
    static let dotLottie = UTType(filenameExtension: "lottie")
        ?? UTType(exportedAs: "com.airbnb.lottie.dotlottie")
    static let animatedPNG = UTType(filenameExtension: "apng")
        ?? UTType(exportedAs: "org.mozilla.apng")
}

extension OverlaySourceType {
    var allowedContentTypes: [UTType] {
        switch self {
        case .animatedImage:
            [.image, .animatedPNG]
        case .alphaVideo:
            [.movie, .video]
        case .lottie:
            [.json, .dotLottie]
        }
    }

    func acceptsSourceURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        switch self {
        case .animatedImage:
            return ext == "apng" || type?.conforms(to: .image) == true
        case .alphaVideo:
            return type?.conforms(to: .movie) == true
                || type?.conforms(to: .video) == true
        case .lottie:
            return ext == "json" || ext == "lottie" || type?.conforms(to: .json) == true
        }
    }
}

// MARK: - Overlay management (Phase 38b)

extension EditorModel {

    /// Imports an overlay source file and creates an overlay clip at the
    /// playhead position with a default duration of 5 seconds.
    @MainActor
    func importOverlay(from url: URL, sourceType: OverlaySourceType) async {
        guard sourceType.acceptsSourceURL(url) else {
            statusMessage = "Choose a \(sourceType.displayName.lowercased()) source file."
            return
        }

        let generation = sessionGeneration
        let access = url.startAccessingSecurityScopedResource()

        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) else {
            if access { url.stopAccessingSecurityScopedResource() }
            statusMessage = "Could not create bookmark for \(url.lastPathComponent)."
            return
        }
        guard sessionGeneration == generation else {
            if access { url.stopAccessingSecurityScopedResource() }
            return
        }
        retainAccess(url, didStart: access)

        let defaultDuration = CMTime(seconds: 5, preferredTimescale: 600)
        let overlay = OverlayClip(
            sourceType: sourceType,
            timelineStart: CMTime(seconds: currentTime, preferredTimescale: 600),
            duration: defaultDuration)

        performUndoable("Add Overlay") {
            project.overlays.append(overlay)
            project.overlayBookmarks[overlay.id] = bookmark
        }
        if sourceType == .lottie,
           let warning = await LottieFrameSource.unsupportedFeatureWarningAsync(for: url) {
            statusMessage = "Added Lottie overlay — \(warning)"
        } else {
            statusMessage = "Added \(sourceType.displayName) overlay."
        }
        await rebuild()
    }

    /// Removes an overlay clip by ID.
    @MainActor
    func removeOverlay(id: UUID) {
        guard project.overlays.contains(where: { $0.id == id }) else { return }
        performUndoable("Remove Overlay") {
            project.overlays.removeAll { $0.id == id }
            if selectedOverlayID == id {
                selectedOverlayID = nil
            }
            if let bookmark = project.overlayBookmarks[id],
               let url = resolveBookmark(bookmark) {
                if let removed = accessedURLs.remove(url) {
                    removed.stopAccessingSecurityScopedResource()
                }
            }
            project.overlayBookmarks.removeValue(forKey: id)
            project.overlayBundlePaths.removeValue(forKey: id)
        }
        statusMessage = "Removed overlay."
        Task { [weak self] in await self?.rebuild() }
    }

    /// Updates an overlay clip's properties.
    @MainActor
    func updateOverlay(_ updated: OverlayClip) {
        guard let index = project.overlays.firstIndex(where: { $0.id == updated.id }) else { return }
        performCoalescedUndoable("Edit Overlay", target: updated.id, rebuild: .immediate) {
            project.overlays[index] = updated
        }
    }

    /// Moves an overlay to a new position in the list (changes z-order).
    @MainActor
    func moveOverlay(id: UUID, to newIndex: Int) {
        guard let currentIndex = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        let clampedIndex = max(0, min(newIndex, project.overlays.count - 1))
        guard currentIndex != clampedIndex else { return }
        performUndoable("Reorder Overlay") {
            let overlay = project.overlays.remove(at: currentIndex)
            project.overlays.insert(overlay, at: clampedIndex)
        }
        Task { [weak self] in await self?.rebuild() }
    }

    /// Updates the overlay's timeline start time.
    @MainActor
    func setOverlayStart(_ id: UUID, to start: CMTime) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Move Overlay", target: id, rebuild: .immediate) {
            project.overlays[index].timelineStart = start
        }
    }

    /// Updates the overlay's duration.
    @MainActor
    func setOverlayDuration(_ id: UUID, to duration: CMTime) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Resize Overlay", target: id, rebuild: .immediate) {
            project.overlays[index].duration = max(CMTime(value: 1, timescale: 600), duration)
        }
    }

    /// Updates the overlay's position offset.
    @MainActor
    func setOverlayPosition(_ id: UUID, to offset: CGSize) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Move Overlay", target: id, rebuild: .debounced) {
            project.overlays[index].positionOffset = offset
        }
    }

    /// Updates the overlay's scale.
    @MainActor
    func setOverlayScale(_ id: UUID, to scale: CGFloat) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Scale Overlay", target: id, rebuild: .debounced) {
            project.overlays[index].scale = max(0.1, scale)
        }
    }

    /// Updates the overlay's rotation.
    @MainActor
    func setOverlayRotation(_ id: UUID, to rotation: CGFloat) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Rotate Overlay", target: id, rebuild: .debounced) {
            project.overlays[index].rotation = rotation
        }
    }

    /// Updates the overlay's opacity.
    @MainActor
    func setOverlayOpacity(_ id: UUID, to opacity: Float) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Overlay Opacity", target: id, rebuild: .debounced) {
            project.overlays[index].opacity = max(0, min(1, opacity))
        }
    }

    /// Updates the overlay's end action.
    @MainActor
    func setOverlayEndAction(_ id: UUID, to action: OverlayEndAction) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performUndoable("Overlay End Action") {
            project.overlays[index].endAction = action
        }
        Task { [weak self] in await self?.rebuild() }
    }

    /// Resolves the source URL for an overlay from its bookmark or bundle path.
    func resolveOverlayURL(for overlay: OverlayClip) -> URL? {
        // Try bundle-relative path first.
        if let relativePath = project.overlayBundlePaths[overlay.id],
           ProjectBundleLayout.isSafeAssetRelativePath(relativePath),
           let bundleURL = documentURL {
            let url = bundleURL.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        // Fall back to security-scoped bookmark.
        guard let bookmark = project.overlayBookmarks[overlay.id], !bookmark.isEmpty else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isStale,
           let refreshed = refreshedOverlayBookmark(for: url) {
            project.overlayBookmarks[overlay.id] = refreshed
        }
        return url
    }

    private func refreshedOverlayBookmark(for url: URL) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: .withSecurityScope,
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
    }

    /// Registers overlay frame sources with the compositor for the current
    /// project's overlays. Called during composition rebuild.
    @MainActor
    func registerOverlaySources(purpose: OverlaySourceRegistryPurpose = .transient) async -> UUID? {
        var sources: [UUID: any OverlayFrameSource] = [:]
        for overlay in project.overlays {
            guard let url = resolveOverlayURL(for: overlay) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let source = await OverlayFrameSourceFactory.makeSource(for: overlay, sourceURL: url) else {
                continue
            }
            sources[overlay.id] = source
        }
        return EffectCompositor.registerOverlaySources(sources, purpose: purpose)
    }

    private func resolveBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale)
    }
}
