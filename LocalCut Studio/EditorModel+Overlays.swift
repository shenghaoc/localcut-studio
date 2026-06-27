import Foundation
import AVFoundation
import CoreGraphics
import LocalCutCore

// MARK: - Overlay management (Phase 38b)

extension EditorModel {

    /// Imports an overlay source file and creates an overlay clip at the
    /// playhead position with a default duration of 5 seconds.
    @MainActor
    func importOverlay(from url: URL, sourceType: OverlaySourceType) async {
        let generation = sessionGeneration
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) else {
            statusMessage = "Could not create bookmark for \(url.lastPathComponent)."
            return
        }
        guard sessionGeneration == generation else { return }

        let defaultDuration = CMTime(seconds: 5, preferredTimescale: 600)
        let overlay = OverlayClip(
            sourceType: sourceType,
            timelineStart: CMTime(seconds: currentTime, preferredTimescale: 600),
            duration: defaultDuration)

        performUndoable("Add Overlay") {
            project.overlays.append(overlay)
            project.overlayBookmarks[overlay.id] = bookmark
        }
        statusMessage = "Added \(sourceType.displayName) overlay."
        await rebuild()
    }

    /// Removes an overlay clip by ID.
    @MainActor
    func removeOverlay(id: UUID) {
        guard project.overlays.contains(where: { $0.id == id }) else { return }
        performUndoable("Remove Overlay") {
            project.overlays.removeAll { $0.id == id }
            project.overlayBookmarks.removeValue(forKey: id)
            project.overlayBundlePaths.removeValue(forKey: id)
        }
        statusMessage = "Removed overlay."
        Task { await rebuild() }
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
        Task { await rebuild() }
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
        performCoalescedUndoable("Move Overlay", target: id, rebuild: .immediate) {
            project.overlays[index].positionOffset = offset
        }
    }

    /// Updates the overlay's scale.
    @MainActor
    func setOverlayScale(_ id: UUID, to scale: CGFloat) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Scale Overlay", target: id, rebuild: .immediate) {
            project.overlays[index].scale = max(0.1, scale)
        }
    }

    /// Updates the overlay's rotation.
    @MainActor
    func setOverlayRotation(_ id: UUID, to rotation: CGFloat) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Rotate Overlay", target: id, rebuild: .immediate) {
            project.overlays[index].rotation = rotation
        }
    }

    /// Updates the overlay's opacity.
    @MainActor
    func setOverlayOpacity(_ id: UUID, to opacity: Float) {
        guard let index = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Overlay Opacity", target: id, rebuild: .immediate) {
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
        Task { await rebuild() }
    }

    /// Resolves the source URL for an overlay from its bookmark or bundle path.
    func resolveOverlayURL(for overlay: OverlayClip) -> URL? {
        // Try bundle-relative path first.
        if let relativePath = project.overlayBundlePaths[overlay.id],
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
        return url
    }

    /// Registers overlay frame sources with the compositor for the current
    /// project's overlays. Called during composition rebuild.
    @MainActor
    func registerOverlaySources() {
        EffectCompositor.clearOverlaySources()
        for overlay in project.overlays {
            guard let url = resolveOverlayURL(for: overlay) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let source = OverlayFrameSourceFactory.makeSource(for: overlay, sourceURL: url) else {
                continue
            }
            EffectCompositor.setOverlaySource(source, for: overlay.id)
        }
    }
}
