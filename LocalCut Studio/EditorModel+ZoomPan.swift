import Foundation
import AppKit
import CoreMedia
import UniformTypeIdentifiers
import LocalCutCore

extension UTType {
    static let localCutZoomPanPreset = UTType(filenameExtension: ZoomPanPresetV1.fileExtension,
                                              conformingTo: .json) ?? .json
}

extension EditorModel {
    // MARK: - Zoom-pan state

    /// The selected clip's current zoom-pan keyframed track.
    var selectedClipZoomPan: Keyframed<ZoomPanKeyframe> {
        get {
            selectedClip?.zoomPan ?? Keyframed(defaultValue: .identity)
        }
    }

    /// Whether the selected clip has any zoom-pan animation.
    var selectedClipHasZoomPan: Bool {
        selectedClipZoomPan.isAnimated
    }

    // MARK: - Preset application

    /// Applies a built-in zoom-pan preset to the selected clip.
    func applyZoomPanPreset(_ preset: ZoomPanPresetV1) {
        guard let id = selectedVideoClipID else {
            statusMessage = "Select a video clip before applying a zoom-pan preset."
            return
        }
        guard let clip = selectedClip else { return }

        performUndoable("Apply Zoom-Pan Preset") {
            let keyframes = ZoomPanValidator.clamped(
                preset.stamping(onto: clip.duration).keyframes,
                duration: clip.duration)
            let zoomPan = Keyframed(keyframes: keyframes, defaultValue: .identity)
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                track.clips[index].zoomPan = zoomPan
                RenderCache.shared.invalidate(clipID: id)
                statusMessage = "Applied zoom-pan preset \(preset.name)."
                scheduleRebuild()
                return
            }
        }
    }

    /// Resets the selected clip's zoom-pan to identity (no animation).
    func resetZoomPan() {
        guard let id = selectedVideoClipID else { return }
        performUndoable("Reset Zoom-Pan") {
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                track.clips[index].zoomPan = Keyframed(defaultValue: .identity)
                RenderCache.shared.invalidate(clipID: id)
                statusMessage = "Reset zoom-pan."
                scheduleRebuild()
                return
            }
        }
    }

    // MARK: - Zoom-pan keyframe CRUD

    /// Source-local playhead time for the selected video clip, or nil when the
    /// playhead is outside the clip.
    private var selectedClipZoomPanLocalPlayheadTime: CMTime? {
        selectedClipSourceLocalPlayheadTime
    }

    /// Returns the zoom-pan value at the current playhead position.
    func zoomPanAtPlayhead() -> ZoomPanKeyframe {
        let track = selectedClipZoomPan
        guard let time = selectedClipZoomPanLocalPlayheadTime else { return track.defaultValue }
        return track.value(at: time)
    }

    /// Returns the zoom-pan keyframe at the playhead, if any.
    func zoomPanKeyframeAtPlayhead() -> Keyframe<ZoomPanKeyframe>? {
        guard let time = selectedClipZoomPanLocalPlayheadTime else { return nil }
        return nearestZoomPanKeyframe(to: time)
    }

    /// Adds or updates a zoom-pan keyframe at the current playhead position.
    func addOrUpdateZoomPanKeyframe(value: ZoomPanKeyframe? = nil) {
        guard let id = selectedVideoClipID,
              let localTime = selectedClipZoomPanLocalPlayheadTime else {
            statusMessage = "Move the playhead over the selected clip to add a keyframe."
            return
        }
        let existingID = zoomPanKeyframeAtPlayhead()?.id
        let keyframeValue = value ?? zoomPanAtPlayhead()
        performUndoable(existingID == nil ? "Add Zoom-Pan Keyframe" : "Update Zoom-Pan Keyframe") {
            mutateZoomPan(clipID: id) { track in
                if let existingID {
                    track.updateKeyframe(id: existingID, time: localTime, value: keyframeValue)
                } else {
                    track.addKeyframe(at: localTime, value: keyframeValue)
                }
            }
            statusMessage = "Zoom-pan keyframe set at \(TimeFormatting.timecode(localTime.seconds))."
        }
    }

    /// Removes the zoom-pan keyframe at the playhead, if any.
    func removeZoomPanKeyframe() {
        guard let id = selectedVideoClipID,
              let keyframe = zoomPanKeyframeAtPlayhead() else {
            statusMessage = "No zoom-pan keyframe at the playhead."
            return
        }
        performUndoable("Remove Zoom-Pan Keyframe") {
            mutateZoomPan(clipID: id) { track in
                track.removeKeyframe(id: keyframe.id)
            }
            statusMessage = "Removed zoom-pan keyframe."
        }
    }

    /// Seeks to the previous zoom-pan keyframe.
    func seekToPreviousZoomPanKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipZoomPanLocalPlayheadTime else { return }
        let tolerance = zoomPanKeyframeHitToleranceSeconds
        guard let previous = selectedClipZoomPan.keyframes.last(where: {
            $0.time.seconds < localTime.seconds - tolerance
        }) else { return }
        let outputOffset = clip.outputOffset(forSourceOffset: previous.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    /// Seeks to the next zoom-pan keyframe.
    func seekToNextZoomPanKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipZoomPanLocalPlayheadTime else { return }
        let tolerance = zoomPanKeyframeHitToleranceSeconds
        guard let next = selectedClipZoomPan.keyframes.first(where: {
            $0.time.seconds > localTime.seconds + tolerance
        }) else { return }
        let outputOffset = clip.outputOffset(forSourceOffset: next.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    /// Applies a zoom-pan keyframe stamp from an auto-zoom proposal.
    func applyAutoZoomProposal(_ keyframes: [Keyframe<ZoomPanKeyframe>]) {
        guard let id = selectedVideoClipID,
              let clip = selectedClip else { return }
        let clamped = ZoomPanValidator.clamped(keyframes, duration: clip.duration)
        performUndoable("Apply Auto-Zoom") {
            let zoomPan = Keyframed(keyframes: clamped, defaultValue: .identity)
            for track in project.videoTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                track.clips[index].zoomPan = zoomPan
                RenderCache.shared.invalidate(clipID: id)
                statusMessage = "Applied auto-zoom proposal."
                scheduleRebuild()
                return
            }
        }
    }

    // MARK: - Import / Export

    func importZoomPanPreset(url: URL) async {
        guard selectedVideoClipID != nil else {
            statusMessage = "Select a video clip before importing a zoom-pan preset."
            return
        }
        do {
            let data = try await Task.detached {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                return try Data(contentsOf: url)
            }.value
            let preset = try JSONDecoder().decode(ZoomPanPresetV1.self, from: data)
            applyZoomPanPreset(preset)
        } catch {
            statusMessage = "Could not import \(url.lastPathComponent)."
        }
    }

    func requestExportZoomPanPreset() {
        guard let clip = selectedClip,
              selectedVideoClipID != nil else {
            statusMessage = "Select a video clip before exporting a zoom-pan preset."
            return
        }
        guard selectedClipHasZoomPan else {
            statusMessage = "The selected clip has no zoom-pan animation to export."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.localCutZoomPanPreset]
        panel.nameFieldStringValue = "\(defaultZoomPanPresetName(for: clip)).\(ZoomPanPresetV1.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportZoomPanPreset(to: url)
    }

    func exportZoomPanPreset(to url: URL) {
        guard let clip = selectedClip else { return }
        let preset = ZoomPanPresetV1(name: defaultZoomPanPresetName(for: clip),
                                     keyframes: clip.zoomPan.keyframes.map {
            ZoomPanPresetV1.PresetKeyframe(
                t: clip.duration.seconds > 0 ? $0.time.seconds / clip.duration.seconds : 0,
                value: $0.value,
                incomingHandle: $0.incomingHandle,
                outgoingHandle: $0.outgoingHandle)
        })
        Task {
            do {
                let data = try JSONEncoder().encode(preset)
                try await Task.detached {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    try data.write(to: url, options: [.atomic])
                }.value
                statusMessage = "Exported zoom-pan preset \(url.lastPathComponent)."
            } catch {
                statusMessage = "Could not export \(url.lastPathComponent)."
            }
        }
    }

    // MARK: - Private helpers

    private var zoomPanKeyframeHitToleranceSeconds: Double {
        0.5 / max(1, project.frameRate)
    }

    private func nearestZoomPanKeyframe(to time: CMTime) -> Keyframe<ZoomPanKeyframe>? {
        let tolerance = zoomPanKeyframeHitToleranceSeconds
        return selectedClipZoomPan.keyframes
            .map { keyframe in (keyframe, abs((keyframe.time - time).seconds)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func mutateZoomPan(clipID: Clip.ID,
                               _ transform: (inout Keyframed<ZoomPanKeyframe>) -> Void) {
        for track in project.videoTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == clipID }) else { continue }
            var zoomPan = track.clips[index].zoomPan
            transform(&zoomPan)
            track.clips[index].zoomPan = zoomPan
            RenderCache.shared.invalidate(clipID: clipID)
            scheduleRebuild()
            return
        }
    }

    private func defaultZoomPanPresetName(for clip: Clip) -> String {
        let mediaName = project.media(for: clip.mediaID)?.name ?? "Clip"
        let stem = (mediaName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Clip" : stem
        return "\(base) Zoom-Pan"
    }
}
