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

            // Speed and skin-smooth keyframes are clip-source-relative. Split each
            // track at the cut with an evaluated boundary keyframe so both halves
            // preserve the original ramp; without it a lone surviving keyframe
            // would flatten the ramp and the left half would no longer end exactly
            // at the playhead.
            let (leftSpeed, rightSpeed) = Self.splitKeyframeTrack(clip.speedCurve, at: sourceOffset)

            var left = clip
            left.duration = sourceOffset
            left.speedCurve = leftSpeed
            left.effects = Self.mapSkinSmoothStrength(in: clip.effects) {
                Self.splitKeyframeTrack($0, at: sourceOffset).left
            }

            // Carry the authored envelope to the right half so a split doesn't
            // silently drop volume automation. The render-time fade clamp already
            // trims fades that no longer fit either side's duration.
            let rightEffects = Self.mapSkinSmoothStrength(in: clip.effects) {
                Self.splitKeyframeTrack($0, at: sourceOffset).right
            }
            let right = Clip(mediaID: clip.mediaID,
                             sourceStart: clip.sourceStart + sourceOffset,
                             duration: clip.duration - sourceOffset,
                             timelineStart: playhead,
                             opacity: clip.opacity,
                             effects: rightEffects,
                             volumeEnvelope: clip.volumeEnvelope,
                             speedCurve: rightSpeed,
                             preservePitch: clip.preservePitch,
                             pitchAlgorithm: clip.pitchAlgorithm)

            track.clips.replaceSubrange(index...index, with: [left, right])
            model.selectedClipID = left.id
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
                    let startSpeed = Double(TimeRemapping.clampedSpeed(clip.speedCurve.value(at: .zero)))
                    let originalEnd = clip.timelineEnd
                    var newTimelineStart = max(time, .zero)
                    // The head can extend earlier only until the unused source
                    // before `sourceStart` runs out; that span plays at the
                    // start-edge speed, so convert it to output time.
                    let maxExtendOutput = CMTime(seconds: clip.sourceStart.seconds / max(startSpeed, 0.0001),
                                                 preferredTimescale: 600)
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
                    clip.sourceStart = CMTimeMaximum(.zero, clip.sourceStart + sourceDelta)
                    clip.timelineStart = newTimelineStart
                    clip.duration = CMTimeMaximum(clip.duration - sourceDelta, .zero)
                    // Source origin moved by `sourceDelta`; rebase the
                    // clip-source-relative speed and skin-smooth keyframes so the
                    // ramps stay pinned to the same media frames after the trim.
                    clip.speedCurve = Self.rebaseKeyframeTrack(clip.speedCurve, originShiftedBy: sourceDelta)
                    clip.effects = Self.mapSkinSmoothStrength(in: clip.effects) {
                        Self.rebaseKeyframeTrack($0, originShiftedBy: sourceDelta)
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
                    // Drop speed and skin-smooth keyframes past the new source
                    // duration so stale out-of-range entries don't linger.
                    clip.speedCurve = Self.clampKeyframeTrack(clip.speedCurve, toDuration: newDuration)
                    clip.effects = Self.mapSkinSmoothStrength(in: clip.effects) {
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
        guard size != model.project.renderSize else { return }
        model.performUndoable("Change Resolution") {
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
        guard track.isAnimated else { return (track, track) }
        let boundary = track.value(at: cut)
        var leftKeys = track.keyframes.filter { $0.time < cut }
        leftKeys.append(Keyframe<Float>(time: cut, value: boundary))
        var rightKeys = [Keyframe<Float>(time: .zero, value: boundary)]
        rightKeys.append(contentsOf: track.keyframes.compactMap { kf in
            let newTime = kf.time - cut
            guard newTime > .zero else { return nil }
            return Keyframe<Float>(id: kf.id, time: newTime, value: kf.value)
        })
        return (Keyframed<Float>(keyframes: leftKeys, defaultValue: track.defaultValue),
                Keyframed<Float>(keyframes: rightKeys, defaultValue: track.defaultValue))
    }

    /// Re-bases a clip-source-relative keyframe track when the source origin moves
    /// by `sourceDelta` (positive = trimmed in from the head, negative = extended
    /// earlier). Keyframes that fall before the new origin are dropped.
    private static func rebaseKeyframeTrack(_ track: Keyframed<Float>, originShiftedBy sourceDelta: CMTime)
        -> Keyframed<Float> {
        Keyframed<Float>(
            keyframes: track.keyframes.compactMap { kf in
                let newTime = kf.time - sourceDelta
                guard newTime >= .zero else { return nil }
                return Keyframe<Float>(id: kf.id, time: newTime, value: kf.value)
            },
            defaultValue: track.defaultValue)
    }

    /// Drops keyframes past `newDuration` from a clip-source-relative track.
    private static func clampKeyframeTrack(_ track: Keyframed<Float>, toDuration newDuration: CMTime)
        -> Keyframed<Float> {
        Keyframed<Float>(
            keyframes: track.keyframes.filter { $0.time <= newDuration },
            defaultValue: track.defaultValue)
    }

    /// Applies `transform` to every skin-smooth effect's strength track in
    /// `effects`, leaving other effects untouched. Skin-smooth strength keyframes
    /// are evaluated in clip-source-local time, so they must be rebased alongside
    /// `speedCurve` whenever a source edit moves the clip's origin or duration.
    private static func mapSkinSmoothStrength(in effects: [Effect],
                                             _ transform: (Keyframed<Float>) -> Keyframed<Float>) -> [Effect] {
        effects.map { effect in
            guard case .skinSmooth(var smooth) = effect else { return effect }
            smooth.strength = transform(smooth.strength)
            return .skinSmooth(smooth)
        }
    }

    private func allTracks(in model: EditorModel) -> [Track] {
        model.project.videoTracks + model.project.audioTracks
    }

    private func minClipDuration(model: EditorModel) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, model.project.frameRate)))
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
        let duration = clip.duration
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
