import Foundation
import CoreMedia
import CoreGraphics
import LocalCutCore

// MARK: - Callout management (Phase 43)

extension EditorModel {

    /// Adds a new callout clip at the current playhead position with a default
    /// duration and the given kind.
    @MainActor
    func addCallout(kind: CalloutKind) {
        let defaultDuration = CMTime(seconds: 3, preferredTimescale: 600)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: currentTime, preferredTimescale: 600),
            duration: defaultDuration)

        // Assign sequential step numbers for step-number callouts.
        let stepNumber: Int
        if kind == .stepNumber {
            let existingSteps = project.callouts.filter { $0.kind == .stepNumber }
            stepNumber = (existingSteps.map(\.stepNumber).max() ?? 0) + 1
        } else {
            stepNumber = 1
        }

        let callout = CalloutClip(kind: kind, timeRange: timeRange, stepNumber: stepNumber)
        performUndoable("Add \(kind.displayName) Callout") {
            project.callouts.append(callout)
        }
        selectedCalloutID = callout.id
        statusMessage = "Added \(kind.displayName.lowercased()) callout."
        Task { await rebuild() }
    }

    /// Removes a callout clip by ID.
    @MainActor
    func removeCallout(id: UUID) {
        guard project.callouts.contains(where: { $0.id == id }) else { return }
        performUndoable("Remove Callout") {
            project.callouts.removeAll { $0.id == id }
            if selectedCalloutID == id {
                selectedCalloutID = nil
            }
        }
        statusMessage = "Removed callout."
        Task { await rebuild() }
    }

    /// Updates a callout clip's properties.
    @MainActor
    func updateCallout(_ updated: CalloutClip) {
        guard let index = project.callouts.firstIndex(where: { $0.id == updated.id }) else { return }
        performCoalescedUndoable("Edit Callout", target: updated.id, rebuild: .debounced) {
            project.callouts[index] = updated
        }
    }

    /// Returns the callout with the given ID, or nil.
    func callout(for id: UUID) -> CalloutClip? {
        project.callouts.first(where: { $0.id == id })
    }

    var selectedCalloutLocalPlayheadTime: CMTime? {
        guard let callout = selectedCallout else { return nil }
        let playhead = CMTime(seconds: currentTime, preferredTimescale: 600)
        guard playhead >= callout.timeRange.start,
              playhead <= callout.timeRange.start + callout.timeRange.duration else { return nil }
        return CMTimeMaximum(.zero, playhead - callout.timeRange.start)
    }

    var selectedCalloutTransformAtPlayhead: Transform2D {
        guard let callout = selectedCallout else { return .identity }
        guard let localTime = selectedCalloutLocalPlayheadTime,
              callout.transformKeyframes.isAnimated else {
            return staticTransform(for: callout)
        }
        return callout.transformKeyframes.value(at: localTime)
    }

    var selectedCalloutTransformKeyframeAtPlayhead: Keyframe<Transform2D>? {
        guard let callout = selectedCallout,
              let localTime = selectedCalloutLocalPlayheadTime else { return nil }
        return nearestCalloutTransformKeyframe(in: callout.transformKeyframes, to: localTime)
    }

    var selectedCalloutTransformKeyframeCount: Int {
        selectedCallout?.transformKeyframes.keyframes.count ?? 0
    }

    /// Adds or updates a transform keyframe at the current playhead. The first
    /// keyframe promotes the static transform into the animation track and
    /// neutralises the static fields so the compositor does not double-apply it.
    @MainActor
    func addOrUpdateSelectedCalloutTransformKeyframe() {
        guard let id = selectedCalloutID,
              let index = project.callouts.firstIndex(where: { $0.id == id }),
              let localTime = selectedCalloutLocalPlayheadTime else {
            statusMessage = "Move the playhead over the selected callout to add a keyframe."
            return
        }

        let callout = project.callouts[index]
        let existingID = selectedCalloutTransformKeyframeAtPlayhead?.id
        let wasAnimated = callout.transformKeyframes.isAnimated
        let value = wasAnimated
            ? callout.transformKeyframes.value(at: localTime)
            : staticTransform(for: callout)

        performUndoable(existingID == nil ? "Add Callout Keyframe" : "Update Callout Keyframe") {
            if let existingID {
                project.callouts[index].transformKeyframes.updateKeyframe(
                    id: existingID,
                    time: localTime,
                    value: value)
            } else {
                project.callouts[index].transformKeyframes.addKeyframe(at: localTime, value: value)
            }
            if !wasAnimated {
                project.callouts[index].positionOffset = .zero
                project.callouts[index].scale = 1
                project.callouts[index].rotation = 0
            }
            scheduleRebuild()
        }
        statusMessage = "Callout keyframe set at \(TimeFormatting.timecode(localTime.seconds))."
    }

    @MainActor
    func removeSelectedCalloutTransformKeyframe() {
        guard let id = selectedCalloutID,
              let index = project.callouts.firstIndex(where: { $0.id == id }),
              let keyframe = selectedCalloutTransformKeyframeAtPlayhead else {
            statusMessage = "No callout transform keyframe at the playhead."
            return
        }

        performUndoable("Remove Callout Keyframe") {
            project.callouts[index].transformKeyframes.removeKeyframe(id: keyframe.id)
            scheduleRebuild()
        }
        statusMessage = "Removed callout keyframe."
    }

    @MainActor
    func updateSelectedCalloutTransformKeyframeValue(_ value: Transform2D) {
        guard let id = selectedCalloutID,
              let index = project.callouts.firstIndex(where: { $0.id == id }),
              let keyframe = selectedCalloutTransformKeyframeAtPlayhead else { return }

        performCoalescedUndoable("Edit Callout Keyframe", target: keyframe.id, rebuild: .immediate) {
            project.callouts[index].transformKeyframes.updateKeyframe(id: keyframe.id, value: value)
        }
    }

    @MainActor
    func seekToPreviousSelectedCalloutTransformKeyframe() {
        guard let callout = selectedCallout,
              let localTime = selectedCalloutLocalPlayheadTime else { return }
        let tolerance = calloutKeyframeHitToleranceSeconds
        guard let previous = callout.transformKeyframes.keyframes.last(where: {
            $0.time.seconds < localTime.seconds - tolerance
        }) else { return }
        seek(toSeconds: (callout.timeRange.start + previous.time).seconds)
    }

    @MainActor
    func seekToNextSelectedCalloutTransformKeyframe() {
        guard let callout = selectedCallout,
              let localTime = selectedCalloutLocalPlayheadTime else { return }
        let tolerance = calloutKeyframeHitToleranceSeconds
        guard let next = callout.transformKeyframes.keyframes.first(where: {
            $0.time.seconds > localTime.seconds + tolerance
        }) else { return }
        seek(toSeconds: (callout.timeRange.start + next.time).seconds)
    }

    private var selectedCallout: CalloutClip? {
        guard let selectedCalloutID else { return nil }
        return callout(for: selectedCalloutID)
    }

    private var calloutKeyframeHitToleranceSeconds: Double {
        0.5 / max(1, project.frameRate)
    }

    private func nearestCalloutTransformKeyframe(in keyframes: Keyframed<Transform2D>,
                                                 to time: CMTime) -> Keyframe<Transform2D>? {
        let tolerance = calloutKeyframeHitToleranceSeconds
        return keyframes.keyframes
            .map { keyframe in (keyframe, abs((keyframe.time - time).seconds)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func staticTransform(for callout: CalloutClip) -> Transform2D {
        Transform2D(
            translateX: Float(callout.positionOffset.width),
            translateY: Float(callout.positionOffset.height),
            scale: callout.scale,
            rotation: callout.rotation)
    }
}
