import Foundation
import CoreGraphics
import CoreMedia
import LocalCutCore

@MainActor
final class ProjectEditingService {
    func addToTimeline(mediaID: MediaItem.ID, model: EditorModel) {
        guard let media = model.project.media(for: mediaID) else { return }
        model.performUndoable("Add Clip") {
            let insertAt = model.project.duration
            let fullRange = CMTimeRange(start: .zero, duration: media.duration)

            if media.hasVideo, let track = model.project.videoTracks.first {
                track.clips.append(Clip(mediaID: mediaID,
                                        sourceStart: fullRange.start,
                                        duration: fullRange.duration,
                                        timelineStart: insertAt))
            }
            if media.hasAudio, let track = model.project.audioTracks.first {
                track.clips.append(Clip(mediaID: mediaID,
                                        sourceStart: fullRange.start,
                                        duration: fullRange.duration,
                                        timelineStart: insertAt))
            }
            model.statusMessage = "Added \(media.name) to timeline."
            model.scheduleRebuild()
        }
    }

    func deleteSelectedClip(model: EditorModel) {
        guard let id = model.selectedClipID else { return }
        model.performUndoable("Delete Clip") {
            for track in allTracks(in: model) {
                track.clips.removeAll { $0.id == id }
            }
            model.selectedClipID = nil
            model.selectedOverlayID = nil
            sanitizeTransitions(model: model)
            model.statusMessage = "Deleted clip."
            model.scheduleRebuild()
        }
    }

    func removeMedia(itemID: MediaItem.ID, model: EditorModel) {
        guard let media = model.project.media(for: itemID) else { return }
        model.performUndoable("Remove Media") {
            model.project.mediaItems.removeAll { $0.id == itemID }
            releaseAccessIfUnused(for: media.url, model: model)
            for track in allTracks(in: model) {
                track.clips.removeAll { $0.mediaID == itemID }
            }
            if model.selectedMediaID == itemID { model.selectedMediaID = nil }
            if let selectedClipID = model.selectedClipID, model.clip(for: selectedClipID) == nil {
                model.selectedClipID = nil
                model.selectedOverlayID = nil
            }
            if let selectedTransitionClipID = model.selectedTransitionClipID,
               model.clip(for: selectedTransitionClipID) == nil {
                model.selectedTransitionClipID = nil
            }
            sanitizeTransitions(model: model)
            model.statusMessage = "Removed \(media.name)."
            model.scheduleRebuild()
        }
    }

    func splitSelectedClipAtPlayhead(model: EditorModel) {
        guard let id = model.selectedClipID else { return }

        var targetTrack: Track?
        var targetIndex: Int?
        for track in allTracks(in: model) {
            if let index = track.clips.firstIndex(where: { $0.id == id }) {
                targetTrack = track
                targetIndex = index
                break
            }
        }
        guard let track = targetTrack, let index = targetIndex else { return }
        let clip = track.clips[index]
        let cuts = TransitionLayout.cuts(videoTracks: model.project.videoTracks.map(\.clips))
        let placements = TransitionLayout.placements(for: track.clips, cuts: cuts)
        let shift = placements.first(where: { $0.id == id })
            .map { clip.timelineStart - $0.effectiveStart } ?? .zero
        let playhead = CMTime(seconds: model.currentTime, preferredTimescale: 600) + shift

        guard playhead > clip.timelineStart, playhead < clip.timelineEnd else { return }

        model.performUndoable("Split Clip") {
            let outputOffset = playhead - clip.timelineStart
            let sourceOffset = clip.sourceOffset(forOutputOffset: outputOffset)

            // Clip animation tracks are source-relative. Split each curve at the
            // cut so both halves preserve the original value and Bezier shape.
            let (leftSpeed, rightSpeed) = Self.splitKeyframeTrack(clip.speedCurve, at: sourceOffset)
            let (leftTransform, rightTransform) = clip.transformKeyframes
                .splitPreservingBezier(at: sourceOffset)

            var left = clip
            left.duration = sourceOffset
            left.speedCurve = leftSpeed
            left.transformKeyframes = leftTransform
            left.effects = clip.effects.mapSourceLocalKeyframeTracks {
                Self.splitKeyframeTrack($0, at: sourceOffset).left
            }

            // Carry the authored envelope to the right half so a split doesn't
            // silently drop volume automation. The render-time fade clamp already
            // trims fades that no longer fit either side's duration.
            let rightEffects = clip.effects.mapSourceLocalKeyframeTracks {
                Self.splitKeyframeTrack($0, at: sourceOffset).right
            }
            let right = Clip(mediaID: clip.mediaID,
                             sourceStart: clip.sourceStart + sourceOffset,
                             duration: clip.duration - sourceOffset,
                             timelineStart: playhead,
                             opacity: clip.opacity,
                             effects: rightEffects,
                             volumeEnvelope: clip.volumeEnvelope,
                             transformKeyframes: rightTransform,
                             speedCurve: rightSpeed,
                             preservePitch: clip.preservePitch,
                             pitchAlgorithm: clip.pitchAlgorithm)

            track.clips.replaceSubrange(index...index, with: [left, right])
            model.selectedClipID = left.id
            model.selectedOverlayID = nil
            model.statusMessage = "Split clip."
            model.scheduleRebuild()
        }
    }

    func updateSelectedClipCoalesced(_ actionName: String = "Adjust Clip",
                                     model: EditorModel,
                                     _ transform: @escaping (inout Clip) -> Void) {
        guard let id = model.selectedClipID else { return }
        model.performCoalescedUndoable(actionName, target: id, rebuild: .debounced) {
            for track in allTracks(in: model) {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                let effectsBefore = track.clips[index].effects
                transform(&track.clips[index])
                if track.clips[index].effects != effectsBefore {
                    RenderCache.shared.invalidate(clipID: id)
                }
                return
            }
        }
    }

    func trimClip(id: Clip.ID, edge: EditorModel.TrimEdge, to time: CMTime, model: EditorModel) {
        model.performCoalescedUndoable("Trim Clip", target: id, rebuild: .immediate) {
            for track in allTracks(in: model) {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                var clip = track.clips[index]
                guard let media = model.project.media(for: clip.mediaID) else { return }
                let sourceDuration = media.duration
                let minDur = minClipDuration(model: model)

                let sorted = track.clips.sorted { $0.timelineStart < $1.timelineStart }
                guard let sortedIndex = sorted.firstIndex(where: { $0.id == id }) else { return }
                let prevClip = sortedIndex > 0 ? sorted[sortedIndex - 1] : nil
                let nextClip = sortedIndex < sorted.count - 1 ? sorted[sortedIndex + 1] : nil

                switch edge {
                case .left:
                    let startSpeed = Double(TimeRemapping.speedValue(in: clip.speedCurve, at: .zero))
                    let originalEnd = clip.timelineEnd
                    var newTimelineStart = max(time, .zero)
                    // The head can extend earlier only until the unused source
                    // before `sourceStart` runs out; that span plays at the
                    // start-edge speed, so convert it to output time.
                    let maxExtendOutput = TimeRemapping.multiplied(clip.sourceStart, by: 1.0 / max(startSpeed, 0.0001))
                    let minTimelineStart = clip.timelineStart - maxExtendOutput
                    newTimelineStart = max(newTimelineStart, minTimelineStart)
                    let maxTimelineStart = originalEnd - minDur
                    newTimelineStart = min(newTimelineStart, maxTimelineStart)
                    if let prev = prevClip {
                        newTimelineStart = max(newTimelineStart, prev.timelineEnd)
                    }

                    let outputDelta = newTimelineStart - clip.timelineStart
                    let sourceDelta: CMTime
                    if outputDelta < .zero {
                        // Extending the head earlier: the prepended span sits before
                        // the speed curve's first keyframe (constant start-edge
                        // speed), and `sourceOffset(forOutputOffset:)` clamps
                        // negatives to zero, so map output→source directly here.
                        sourceDelta = CMTime(seconds: outputDelta.seconds * startSpeed, preferredTimescale: 600)
                    } else {
                        sourceDelta = clip.sourceOffset(forOutputOffset: outputDelta)
                    }
                    let newSourceStart = CMTimeMaximum(.zero, clip.sourceStart + sourceDelta)
                    let actualSourceDelta = newSourceStart - clip.sourceStart
                    clip.sourceStart = newSourceStart
                    clip.timelineStart = newTimelineStart
                    clip.duration = CMTimeMaximum(clip.duration - actualSourceDelta, .zero)
                    // Source origin moved by `actualSourceDelta`; rebase every
                    // source-local curve so it stays pinned to the same frames.
                    clip.speedCurve = Self.rebaseKeyframeTrack(clip.speedCurve, originShiftedBy: actualSourceDelta)
                    clip.transformKeyframes = clip.transformKeyframes
                        .shiftedPreservingBezier(by: actualSourceDelta)
                    clip.effects = clip.effects.mapSourceLocalKeyframeTracks {
                        Self.rebaseKeyframeTrack($0, originShiftedBy: actualSourceDelta)
                    }

                case .right:
                    let maxSourceRemaining = sourceDuration - clip.sourceStart
                    let maxOutputDuration = TimeRemapping.outputDuration(
                        sourceDuration: maxSourceRemaining,
                        speedCurve: clip.speedCurve)
                    var newOutputDuration = time - clip.timelineStart
                    newOutputDuration = max(newOutputDuration, minDur)
                    newOutputDuration = min(newOutputDuration, maxOutputDuration)
                    if let next = nextClip {
                        let maxDuration = next.timelineStart - clip.timelineStart
                        newOutputDuration = min(newOutputDuration, maxDuration)
                    }
                    let newDuration = TimeRemapping.sourceOffset(
                        forOutputOffset: newOutputDuration,
                        sourceDuration: maxSourceRemaining,
                        speedCurve: clip.speedCurve)
                    clip.duration = newDuration
                    // Drop source-local keyframes past the new duration while
                    // preserving each curve at the new tail boundary.
                    clip.speedCurve = Self.clampKeyframeTrack(clip.speedCurve, toDuration: newDuration)
                    clip.transformKeyframes = clip.transformKeyframes
                        .splitPreservingBezier(at: newDuration).left
                    clip.effects = clip.effects.mapSourceLocalKeyframeTracks {
                        Self.clampKeyframeTrack($0, toDuration: newDuration)
                    }
                }

                track.clips[index] = clip
                sanitizeTransitions(model: model)
                return
            }
        }
    }

    func moveClip(id: Clip.ID, toTrack targetTrackID: Track.ID, start: CMTime, model: EditorModel) {
        var sourceTrack: Track?
        var sourceIndex: Int?
        for track in allTracks(in: model) {
            if let index = track.clips.firstIndex(where: { $0.id == id }) {
                sourceTrack = track
                sourceIndex = index
                break
            }
        }
        guard let sourceTrack, let sourceIndex else { return }
        guard let targetTrack = allTracks(in: model).first(where: { $0.id == targetTrackID }) else { return }
        guard sourceTrack.kind == targetTrack.kind else { return }

        model.performCoalescedUndoable("Move Clip", target: id, rebuild: .immediate) {
            var clip = sourceTrack.clips[sourceIndex]
            if clip.transition != nil {
                clip.transition = nil
                if model.selectedTransitionClipID == id { model.selectedTransitionClipID = nil }
            }
            clip.timelineStart = max(start, .zero)

            sourceTrack.clips.remove(at: sourceIndex)
            clip.timelineStart = resolveOverlap(clip: clip, on: targetTrack)
            targetTrack.clips.append(clip)
            targetTrack.clips.sort { $0.timelineStart < $1.timelineStart }

            sanitizeTransitions(model: model)
        }
    }

    func snapTargets(excluding clipID: Clip.ID? = nil, model: EditorModel) -> [CMTime] {
        var targets: [CMTime] = [.zero]
        let effectivePlayhead = CMTime(seconds: model.currentTime, preferredTimescale: 600)
        let cuts = TransitionLayout.cuts(videoTracks: model.project.videoTracks.map(\.clips))
        targets.append(contentsOf: TransitionLayout.authoredTimes(forEffective: effectivePlayhead, cuts: cuts))
        for track in allTracks(in: model) {
            for clip in track.clips where clip.id != clipID {
                targets.append(clip.timelineStart)
                targets.append(clip.timelineEnd)
            }
        }
        // Beat targets must live here (not only in EditorModel.snapTargets) so the
        // trim/move drag path — which calls resolveSnap → this method — actually
        // snaps to beats when the toggle is on.
        if model.snapToBeats {
            targets.append(contentsOf: model.projectedBeatTimes(excluding: clipID))
        }
        return targets
    }

    func resolveSnap(candidate: CMTime,
                     excluding clipID: Clip.ID? = nil,
                     trailingEdgeOffset: CMTime? = nil,
                     threshold: Double? = nil,
                     model: EditorModel) -> CMTime {
        let thresholdSeconds = threshold ?? (8.0 / model.pixelsPerSecond)
        let targets = snapTargets(excluding: clipID, model: model)

        var nearest = candidate
        var minDistance = Double.infinity

        for target in targets {
            let distance = abs((candidate - target).seconds)
            if distance < thresholdSeconds, distance < minDistance {
                minDistance = distance
                nearest = target
            }
        }

        if let offset = trailingEdgeOffset {
            let trailing = candidate + offset
            for target in targets {
                let distance = abs((trailing - target).seconds)
                if distance < thresholdSeconds, distance < minDistance {
                    minDistance = distance
                    nearest = target - offset
                }
            }
        }

        return nearest
    }

    func setRenderSize(_ size: CGSize, model: EditorModel) {
        let size = Self.sanitizedRenderSize(size)
        guard size != model.project.renderSize else { return }
        model.performUndoable("Change Resolution") {
            let shouldPreserveCustomAspect = model.project.aspect == .custom
            model.project.renderSize = size
            model.project.aspect = shouldPreserveCustomAspect
                ? .custom
                : ProjectAspect.infer(width: Double(size.width), height: Double(size.height))
            RenderCache.shared.invalidate(notMatchingRenderSize: size)
            EffectCompositor.purgeCaptionRasterCache()
            model.scheduleRebuild()
        }
    }

    func setProjectAspect(_ aspect: ProjectAspect, model: EditorModel) {
        let size = aspect == .custom ? model.project.renderSize : aspect.defaultRenderSize
        guard aspect != model.project.aspect || size != model.project.renderSize else { return }
        model.performUndoable("Change Aspect") {
            model.project.aspect = aspect
            model.project.renderSize = size
            RenderCache.shared.invalidate(notMatchingRenderSize: size)
            EffectCompositor.purgeCaptionRasterCache()
            model.scheduleRebuild()
        }
    }

    func setFrameRate(_ fps: Double, model: EditorModel) {
        guard fps != model.project.frameRate else { return }
        model.performUndoable("Change Frame Rate") {
            model.project.frameRate = fps
            model.scheduleRebuild()
        }
    }

    func setWorkingColourSpace(_ space: WorkingColourSpace, model: EditorModel) {
        guard space != model.project.workingColourSpace else { return }
        model.performUndoable("Change Working Space") {
            model.project.workingColourSpace = space
            EffectCompositor.purgeCaptionRasterCache()
            model.scheduleRebuild()
        }
    }

    // MARK: - Keyframe rebasing for source edits

    /// Splits a clip-source-relative keyframe track at `cut`, returning halves
    /// that each preserve the original ramp via an evaluated boundary keyframe at
    /// the cut. A constant (un-keyframed) track is returned unchanged on both
    /// sides — there is no ramp to preserve.
    private static func splitKeyframeTrack(_ track: Keyframed<Float>, at cut: CMTime)
        -> (left: Keyframed<Float>, right: Keyframed<Float>) {
        track.splitPreservingBezier(at: cut)
    }

    /// Re-bases a clip-source-relative keyframe track when the source origin moves
    /// by `sourceDelta` (positive = trimmed in from the head, negative = extended
    /// earlier). Keyframes that fall before the new origin are dropped.
    private static func rebaseKeyframeTrack(_ track: Keyframed<Float>, originShiftedBy sourceDelta: CMTime)
        -> Keyframed<Float> {
        track.shiftedPreservingBezier(by: sourceDelta)
    }

    /// Drops keyframes past `newDuration` from a clip-source-relative track,
    /// inserting a boundary keyframe at `newDuration` to preserve the ramp shape.
    private static func clampKeyframeTrack(_ track: Keyframed<Float>, toDuration newDuration: CMTime)
        -> Keyframed<Float> {
        track.splitPreservingBezier(at: newDuration).left
    }

    private func allTracks(in model: EditorModel) -> [Track] {
        model.project.videoTracks + model.project.audioTracks
    }

    private func minClipDuration(model: EditorModel) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, model.project.frameRate)))
    }

    private static func sanitizedRenderSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: sanitizedRenderDimension(size.width),
            height: sanitizedRenderDimension(size.height))
    }

    private static func sanitizedRenderDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 8192 }
        return min(8192, max(2, value.rounded()))
    }

    private func releaseAccessIfUnused(for url: URL, model: EditorModel) {
        guard !model.project.mediaItems.contains(where: { $0.url == url }) else { return }
        if model.accessedURLs.remove(url) != nil {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func sanitizeTransitions(model: EditorModel) {
        for track in allTracks(in: model) {
            let ordered = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            for (position, clip) in ordered.enumerated() where clip.transition != nil {
                let adjacent = position > 0 &&
                    abs((clip.timelineStart - ordered[position - 1].timelineEnd).seconds) < TransitionLayout.adjacencyTolerance
                if !adjacent, let index = track.clips.firstIndex(where: { $0.id == clip.id }) {
                    track.clips[index].transition = nil
                    if model.selectedTransitionClipID == clip.id { model.selectedTransitionClipID = nil }
                }
            }
        }
    }

    private func resolveOverlap(clip: Clip, on track: Track) -> CMTime {
        let requested = clip.timelineStart
        let duration = clip.outputDuration
        let others = track.clips.sorted { $0.timelineStart < $1.timelineStart }

        let requestedEnd = requested + duration
        let hasOverlap = others.contains { other in
            requested < other.timelineEnd && requestedEnd > other.timelineStart
        }
        if !hasOverlap { return requested }

        var candidates: [CMTime] = [.zero]
        for other in others {
            candidates.append(other.timelineEnd)
            let beforeClip = other.timelineStart - duration
            if beforeClip >= .zero {
                candidates.append(beforeClip)
            }
        }

        var bestStart = requested
        var bestDistance = Double.infinity
        for candidate in candidates {
            let candidateEnd = candidate + duration
            let wouldOverlap = others.contains { other in
                candidate < other.timelineEnd && candidateEnd > other.timelineStart
            }
            if !wouldOverlap {
                let distance = abs((candidate - requested).seconds)
                if distance < bestDistance {
                    bestDistance = distance
                    bestStart = candidate
                }
            }
        }
        return bestStart
    }
}

extension Array where Element == Effect {
    /// Maps every clip-source-local scalar animation track owned by an effect.
    /// Colour-grade and LUT effects have no keyframed scalar track.
    func mapSourceLocalKeyframeTracks(
        _ transform: (Keyframed<Float>) -> Keyframed<Float>
    ) -> [Effect] {
        map { effect in
            switch effect {
            case .skinSmooth(var smooth):
                smooth.strength = transform(smooth.strength)
                return .skinSmooth(smooth)
            case .grain(var grain):
                // Editing can insert an overshooting Bezier boundary. Preserve
                // that cubic here; each look node bounds its value when rendered.
                grain.amount = transform(grain.amount)
                return .grain(grain)
            case .halation(var halation):
                halation.strength = transform(halation.strength)
                return .halation(halation)
            case .vignette(var vignette):
                vignette.amount = transform(vignette.amount)
                return .vignette(vignette)
            case .colourGrade, .lut:
                return effect
            }
        }
    }
}
