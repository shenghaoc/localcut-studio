import CoreMedia
import LocalCutCore
import LocalCutDomain

// MARK: - Clip transform keyframes (Phase 43)

extension EditorModel {
    var selectedClipTransformLocalPlayheadTime: CMTime? {
        selectedClipSourceLocalPlayheadTime
    }

    var selectedClipTransformAtPlayhead: Transform2D {
        guard let clip = selectedClip else { return .identity }
        guard let localTime = selectedClipTransformLocalPlayheadTime,
              clip.transformKeyframes.isAnimated else {
            return clip.transformKeyframes.defaultValue
        }
        return clip.transformKeyframes.bezierValue(at: localTime)
    }

    var selectedClipTransformKeyframeAtPlayhead: Keyframe<Transform2D>? {
        guard let clip = selectedClip,
              let localTime = selectedClipTransformLocalPlayheadTime else { return nil }
        return nearestClipTransformKeyframe(in: clip.transformKeyframes, to: localTime)
    }

    var selectedClipTransformKeyframeCount: Int {
        selectedClip?.transformKeyframes.keyframes.count ?? 0
    }

    /// Whether a previous clip-transform keyframe exists before the playhead
    /// (same tolerance as `seekToPreviousSelectedClipTransformKeyframe`).
    var hasPreviousSelectedClipTransformKeyframe: Bool {
        guard let clip = selectedClip,
              let localTime = selectedClipTransformLocalPlayheadTime else { return false }
        let tolerance = clipTransformKeyframeHitToleranceSeconds
        return clip.transformKeyframes.keyframes.contains {
            $0.time.seconds < localTime.seconds - tolerance
        }
    }

    /// Whether a next clip-transform keyframe exists after the playhead
    /// (same tolerance as `seekToNextSelectedClipTransformKeyframe`).
    var hasNextSelectedClipTransformKeyframe: Bool {
        guard let clip = selectedClip,
              let localTime = selectedClipTransformLocalPlayheadTime else { return false }
        let tolerance = clipTransformKeyframeHitToleranceSeconds
        return clip.transformKeyframes.keyframes.contains {
            $0.time.seconds > localTime.seconds + tolerance
        }
    }

    @MainActor
    func addOrUpdateSelectedClipTransformKeyframe() {
        guard let clipID = selectedClipID,
              let localTime = selectedClipTransformLocalPlayheadTime,
              let (trackIndex, clipIndex) = selectedClipTrackAndIndex() else {
            statusMessage = "Move the playhead over the selected clip to add a transform keyframe."
            return
        }

        let existingID = selectedClipTransformKeyframeAtPlayhead?.id
        let value = selectedClipTransformAtPlayhead
        performUndoable(existingID == nil ? "Add Clip Transform Keyframe" : "Update Clip Transform Keyframe") {
            if let existingID {
                project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes.updateKeyframe(
                    id: existingID,
                    time: localTime,
                    value: value)
            } else {
                project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes.addKeyframe(
                    at: localTime,
                    value: value)
            }
        }
        selectedClipID = clipID
        statusMessage = "Clip transform keyframe set at \(TimeFormatting.timecode(localTime.seconds))."
        Task { [weak self] in await self?.rebuild() }
    }

    @MainActor
    func removeSelectedClipTransformKeyframe() {
        guard let keyframe = selectedClipTransformKeyframeAtPlayhead,
              let (trackIndex, clipIndex) = selectedClipTrackAndIndex() else {
            statusMessage = "No clip transform keyframe at the playhead."
            return
        }

        performUndoable("Remove Clip Transform Keyframe") {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes.removeKeyframe(id: keyframe.id)
        }
        statusMessage = "Removed clip transform keyframe."
        Task { [weak self] in await self?.rebuild() }
    }

    @MainActor
    func updateSelectedClipTransformKeyframeValue(_ value: Transform2D) {
        guard let keyframe = selectedClipTransformKeyframeAtPlayhead,
              let (trackIndex, clipIndex) = selectedClipTrackAndIndex() else { return }

        performCoalescedUndoable("Edit Clip Transform Keyframe", target: keyframe.id, rebuild: .immediate) {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes.updateKeyframe(
                id: keyframe.id,
                value: value)
        }
    }

    @MainActor
    func clearClipTransformKeyframes(clipID: UUID) {
        guard let (trackIndex, clipIndex) = trackAndClipIndex(of: clipID) else { return }
        performUndoable("Clear Clip Transform Keyframes") {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes =
                Keyframed(defaultValue: .identity)
        }
        statusMessage = "Cleared clip transform keyframes."
        Task { [weak self] in await self?.rebuild() }
    }

    @MainActor
    func seekToPreviousSelectedClipTransformKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipTransformLocalPlayheadTime else { return }
        let tolerance = clipTransformKeyframeHitToleranceSeconds
        guard let previous = clip.transformKeyframes.keyframes.last(where: {
            $0.time.seconds < localTime.seconds - tolerance
        }) else { return }
        let outputOffset = clip.outputOffset(forSourceOffset: previous.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    @MainActor
    func seekToNextSelectedClipTransformKeyframe() {
        guard let clip = selectedClip,
              let localTime = selectedClipTransformLocalPlayheadTime else { return }
        let tolerance = clipTransformKeyframeHitToleranceSeconds
        guard let next = clip.transformKeyframes.keyframes.first(where: {
            $0.time.seconds > localTime.seconds + tolerance
        }) else { return }
        let outputOffset = clip.outputOffset(forSourceOffset: next.time)
        seek(toSeconds: effectiveTimelineTime(forAuthored: clip.timelineStart + outputOffset).seconds)
    }

    private var clipTransformKeyframeHitToleranceSeconds: Double {
        0.5 / max(1, project.frameRate)
    }

    private func selectedClipTrackAndIndex() -> (trackIndex: Int, clipIndex: Int)? {
        guard let clipID = selectedClipID else { return nil }
        return trackAndClipIndex(of: clipID)
    }

    private func trackAndClipIndex(of clipID: UUID) -> (trackIndex: Int, clipIndex: Int)? {
        guard let trackIndex = project.videoTracks.firstIndex(where: {
            $0.clips.contains(where: { $0.id == clipID })
        }),
              let clipIndex = project.videoTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            return nil
        }
        return (trackIndex, clipIndex)
    }

    private func nearestClipTransformKeyframe(
        in keyframes: Keyframed<Transform2D>,
        to time: CMTime
    ) -> Keyframe<Transform2D>? {
        Self.nearestTransformKeyframe(in: keyframes, to: time,
                                      tolerance: clipTransformKeyframeHitToleranceSeconds)
    }

    /// Shared helper for finding the nearest transform keyframe within a
    /// tolerance. Used by both clip and callout keyframe navigation.
    static func nearestTransformKeyframe(
        in keyframes: Keyframed<Transform2D>,
        to time: CMTime,
        tolerance: Double
    ) -> Keyframe<Transform2D>? {
        keyframes.keyframes
            .map { keyframe in (keyframe, abs((keyframe.time - time).seconds)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }
}
