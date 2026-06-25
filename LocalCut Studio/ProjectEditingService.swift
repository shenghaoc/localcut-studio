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
            let offset = playhead - clip.timelineStart
            var left = clip
            left.duration = offset

            let right = Clip(mediaID: clip.mediaID,
                             sourceStart: clip.sourceStart + offset,
                             duration: clip.duration - offset,
                             timelineStart: playhead,
                             opacity: clip.opacity,
                             effects: clip.effects,
                             volumeEnvelope: clip.volumeEnvelope)

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
                    let originalEnd = clip.timelineEnd
                    var newTimelineStart = max(time, .zero)
                    let minTimelineStart = clip.timelineStart - clip.sourceStart
                    newTimelineStart = max(newTimelineStart, minTimelineStart)
                    let maxTimelineStart = originalEnd - minDur
                    newTimelineStart = min(newTimelineStart, maxTimelineStart)
                    if let prev = prevClip {
                        newTimelineStart = max(newTimelineStart, prev.timelineEnd)
                    }

                    let delta = newTimelineStart - clip.timelineStart
                    clip.sourceStart = clip.sourceStart + delta
                    clip.timelineStart = newTimelineStart
                    clip.duration = originalEnd - newTimelineStart

                case .right:
                    let maxSourceRemaining = sourceDuration - clip.sourceStart
                    var newDuration = time - clip.timelineStart
                    newDuration = max(newDuration, minDur)
                    newDuration = min(newDuration, maxSourceRemaining)
                    if let next = nextClip {
                        let maxDuration = next.timelineStart - clip.timelineStart
                        newDuration = min(newDuration, maxDuration)
                    }
                    clip.duration = newDuration
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
