import Foundation
import CoreMedia
import AVFoundation
import LocalCutCore

// MARK: - Silence Detection (Phase 44)

extension EditorModel {

    /// Whether the silence review sheet should be presented.
    @MainActor
    var hasSilenceProposals: Bool {
        !silenceProposals.isEmpty
    }

    /// Runs silence detection on the selected audio clip's media, falling back
    /// to the first available audio clip when no audio clip is selected.
    @MainActor
    func runSilenceDetection(parameters: SilenceDetectionParameters = SilenceDetectionParameters()) {
        // Cancel any in-flight detection from a previous invocation.
        silenceDetectionTask?.cancel()

        guard let target = silenceDetectionTarget() else {
            statusMessage = "No audio track with media for silence detection."
            return
        }

        let clip = target.clip
        let media = target.media
        let url = media.url
        let params = parameters
        silenceDetectionGeneration += 1
        let detectionGen = silenceDetectionGeneration
        let sourceRange = clip.timeRangeInSource

        silenceDetectionTask = Task { [weak self] in
            do {
                let detector = SilenceDetector()
                let (_, proposals) = try await detector.detect(
                    url: url,
                    parameters: params,
                    timeRange: sourceRange)
                let timelineProposals = proposals.compactMap {
                    Self.timelineProposal($0, for: clip)
                }

                guard let self, self.silenceDetectionGeneration == detectionGen else { return }
                self.silenceProposals = timelineProposals
                if timelineProposals.isEmpty {
                    self.statusMessage = "No silences detected."
                } else {
                    self.statusMessage = "Found \(timelineProposals.count) silence(s). Review to apply."
                }
            } catch {
                guard let self, self.silenceDetectionGeneration == detectionGen else { return }
                self.statusMessage = "Silence detection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Toggles the selection of a single proposal in the review list.
    @MainActor
    func toggleSilenceProposal(_ proposalID: ProposedCut.ID) {
        guard let index = silenceProposals.firstIndex(where: { $0.id == proposalID }) else { return }
        silenceProposals[index].isSelected.toggle()
    }

    /// Applies all selected silence proposals as a single undoable transaction.
    ///
    /// Each proposal is processed in reverse time order so that earlier clip
    /// offsets remain valid as later clips are modified.
    @MainActor
    func applySelectedSilenceProposals() {
        let selected = silenceProposals.filter(\.isSelected).sorted {
            $0.silenceRange.start < $1.silenceRange.start
        }
        guard !selected.isEmpty else {
            statusMessage = "No proposals selected."
            return
        }

        // Coalesce overlapping ranges so that padding-expanded silences
        // that touch or overlap are merged into a single cut, preventing
        // double-deletion when applied sequentially.
        var coalesced: [ProposedCut] = []
        for proposal in selected {
            if var last = coalesced.last,
               proposal.silenceRange.start <= last.silenceRange.end {
                let mergedEnd = max(last.silenceRange.end, proposal.silenceRange.end)
                last.silenceRange = CMTimeRange(start: last.silenceRange.start, end: mergedEnd)
                coalesced[coalesced.count - 1] = last
            } else {
                coalesced.append(proposal)
            }
        }

        // Apply in reverse time order so earlier offsets remain valid.
        let reversed = coalesced.sorted { $0.silenceRange.start > $1.silenceRange.start }

        performUndoable("Remove Silences") {
            for proposal in reversed {
                applySingleProposal(proposal)
            }
            silenceProposals = []
            statusMessage = "Applied \(coalesced.count) silence cut(s)."
            scheduleRebuild()
        }
    }

    /// Cancels the review, discarding all proposals.
    @MainActor
    func cancelSilenceReview() {
        silenceProposals = []
        statusMessage = "Silence review cancelled."
    }

    // MARK: - Private

    nonisolated static func timelineProposal(_ proposal: ProposedCut, for clip: Clip) -> ProposedCut? {
        guard let silenceRange = timelineRange(forSourceRelativeRange: proposal.silenceRange, in: clip) else {
            return nil
        }

        var mapped = proposal
        mapped.silenceRange = silenceRange
        mapped.unpaddedSilenceRange = timelineRange(
            forSourceRelativeRange: proposal.unpaddedSilenceRange,
            in: clip) ?? silenceRange
        return mapped
    }

    /// Applies a single proposal by ripple-deleting the silence range.
    ///
    /// Clips overlapping the silence are split; clips entirely after it are
    /// shifted left so no gap remains. Also ripples caption tracks.
    private func applySingleProposal(_ proposal: ProposedCut) {
        let cutRange = proposal.silenceRange
        let silenceStart = cutRange.start
        let silenceEnd = cutRange.end
        let silenceDuration = cutRange.duration

        let allTracks: [Track] = project.audioTracks + project.videoTracks
        for track in allTracks {
            var newClips: [Clip] = []
            for clip in track.clips {
                let clipStart = clip.timelineStart
                let clipEnd = clip.timelineEnd

                // Clip entirely before silence — keep as-is.
                if clipEnd <= silenceStart {
                    newClips.append(clip)
                    continue
                }

                // Clip entirely after silence — shift left.
                if clipStart >= silenceEnd {
                    var shifted = clip
                    shifted.timelineStart = clipStart - silenceDuration
                    newClips.append(shifted)
                    continue
                }

                // Clip overlaps the silence.
                let overlapStart = max(silenceStart, clipStart)
                let overlapEnd = min(silenceEnd, clipEnd)

                // Left portion (before silence).
                if overlapStart > clipStart {
                    let leftOutputOffset = overlapStart - clipStart
                    let leftSourceOffset = clip.sourceOffset(forOutputOffset: leftOutputOffset)
                    var left = clip
                    left.duration = leftSourceOffset
                    left.volumeEnvelope = Self.volumeEnvelope(
                        clip.volumeEnvelope,
                        slicedTo: CMTimeRange(start: .zero, duration: leftOutputOffset),
                        originalOutputDuration: clip.outputDuration)
                    newClips.append(left)
                }

                // Right portion (after silence) — shifted left.
                // Use Clip init to get a fresh UUID, avoiding duplicate IDs.
                // Shift source-local keyframes (speedCurve, transformKeyframes)
                // backward by rightSourceOffset so they stay aligned with the
                // right portion's new sourceStart.
                // Drop the original transition: the silence cut is not a
                // transition boundary, so keeping it would make
                // TransitionLayout treat the cut as a cross-dissolve/wipe.
                if overlapEnd < clipEnd {
                    let rightOutputOffset = overlapEnd - clipStart
                    let rightSourceOffset = clip.sourceOffset(forOutputOffset: rightOutputOffset)
                    let right = Clip(
                        mediaID: clip.mediaID,
                        sourceStart: clip.sourceStart + rightSourceOffset,
                        duration: clip.duration - rightSourceOffset,
                        timelineStart: overlapEnd - silenceDuration,
                        opacity: clip.opacity,
                        geometry: clip.geometry,
                        effects: clip.effects,
                        transition: nil,
                        volumeEnvelope: Self.volumeEnvelope(
                            clip.volumeEnvelope,
                            slicedTo: CMTimeRange(
                                start: rightOutputOffset,
                                duration: clip.outputDuration - rightOutputOffset),
                            originalOutputDuration: clip.outputDuration),
                        transformKeyframes: clip.transformKeyframes.shifted(by: rightSourceOffset),
                        speedCurve: clip.speedCurve.shifted(by: rightSourceOffset),
                        preservePitch: clip.preservePitch,
                        pitchAlgorithm: clip.pitchAlgorithm)
                    newClips.append(right)
                }
            }
            track.clips = newClips
        }

        rippleCaptionTracks(removing: cutRange)
        rippleMarkers(removing: cutRange)
        rippleOverlays(removing: cutRange)
        rippleCallouts(removing: cutRange)
        rippleKeystrokeOverlays(removing: cutRange)
    }

    private func silenceDetectionTarget() -> (clip: Clip, media: MediaItem)? {
        if let selectedClipID,
           let track = track(for: selectedClipID),
           track.kind == .audio,
           let clip = track.clips.first(where: { $0.id == selectedClipID }),
           let media = project.media(for: clip.mediaID),
           media.hasAudio {
            return (clip, media)
        }

        for track in project.audioTracks {
            for clip in track.clips {
                guard let media = project.media(for: clip.mediaID),
                      media.hasAudio else { continue }
                return (clip, media)
            }
        }
        return nil
    }

    private func rippleCaptionTracks(removing cutRange: CMTimeRange) {
        for captionTrack in project.captionTracks {
            let rippled = captionTrack.lines.compactMap { line -> CaptionLine? in
                guard let range = Self.rippleTimeRange(line.range, removing: cutRange) else {
                    return nil
                }
                let words = line.words?.compactMap { word -> WordTiming? in
                    guard let wordRange = Self.rippleTimeRange(word.range, removing: cutRange) else {
                        return nil
                    }
                    return WordTiming(range: wordRange, word: word.word)
                }
                return CaptionLine(
                    id: line.id,
                    range: range,
                    text: line.text,
                    words: words,
                    style: line.style,
                    styleKeyframes: line.styleKeyframes)
            }
            captionTrack.replaceLines(rippled)
        }
    }

    private func rippleMarkers(removing cutRange: CMTimeRange) {
        for index in project.markers.indices {
            guard let shifted = Self.rippleTime(project.markers[index].time, removing: cutRange, clampInside: true) else {
                continue
            }
            project.markers[index].time = shifted
        }
        project.markers.sort { $0.time < $1.time }
    }

    private func rippleOverlays(removing cutRange: CMTimeRange) {
        project.overlays = project.overlays.compactMap { overlay in
            guard let range = Self.rippleTimeRange(
                CMTimeRange(start: overlay.timelineStart, duration: overlay.duration),
                removing: cutRange) else { return nil }
            var rippled = overlay
            rippled.timelineStart = range.start
            rippled.duration = range.duration
            return rippled
        }
    }

    private func rippleCallouts(removing cutRange: CMTimeRange) {
        project.callouts = project.callouts.compactMap { callout in
            guard let range = Self.rippleTimeRange(callout.timeRange, removing: cutRange) else {
                return nil
            }
            var rippled = callout
            rippled.timeRange = range
            return rippled
        }
    }

    private func rippleKeystrokeOverlays(removing cutRange: CMTimeRange) {
        project.keystrokeOverlayClips = project.keystrokeOverlayClips.compactMap { clip in
            guard let range = Self.rippleTimeRange(clip.timeRange, removing: cutRange) else {
                return nil
            }
            let events = clip.events.compactMap { event -> KeystrokeOverlayEvent? in
                guard let time = Self.rippleTime(event.time, removing: cutRange) else { return nil }
                var rippled = event
                rippled.time = time
                return rippled
            }
            guard !events.isEmpty else { return nil }
            var rippled = clip
            rippled.timeRange = range
            rippled.events = events
            return rippled
        }
    }

    nonisolated static func rippleTimeRange(_ range: CMTimeRange,
                                            removing cutRange: CMTimeRange) -> CMTimeRange? {
        guard range.start.isNumeric,
              range.duration.isNumeric,
              range.duration > .zero,
              cutRange.start.isNumeric,
              cutRange.duration.isNumeric,
              cutRange.duration > .zero else { return range.duration > .zero ? range : nil }

        let rangeEnd = range.end
        let cutStart = cutRange.start
        let cutEnd = cutRange.end
        let cutDuration = cutRange.duration

        if rangeEnd <= cutStart {
            return range
        }
        if range.start >= cutEnd {
            return CMTimeRange(start: range.start - cutDuration, duration: range.duration)
        }

        let overlapStart = CMTimeMaximum(range.start, cutStart)
        let overlapEnd = CMTimeMinimum(rangeEnd, cutEnd)
        let removedDuration = overlapEnd - overlapStart
        let newDuration = range.duration - removedDuration
        guard newDuration > .zero else { return nil }

        let newStart = range.start < cutStart ? range.start : cutStart
        return CMTimeRange(start: newStart, duration: newDuration)
    }

    private nonisolated static func rippleTime(_ time: CMTime,
                                               removing cutRange: CMTimeRange,
                                               clampInside: Bool = false) -> CMTime? {
        guard time.isNumeric,
              cutRange.start.isNumeric,
              cutRange.duration.isNumeric,
              cutRange.duration > .zero else { return time }

        if time < cutRange.start {
            return time
        }
        if time >= cutRange.end {
            return time - cutRange.duration
        }
        return clampInside ? cutRange.start : nil
    }

    private nonisolated static func volumeEnvelope(_ envelope: VolumeEnvelope,
                                                   slicedTo outputRange: CMTimeRange,
                                                   originalOutputDuration: CMTime) -> VolumeEnvelope {
        guard !envelope.isEmpty,
              outputRange.start.isNumeric,
              outputRange.duration.isNumeric,
              outputRange.duration > .zero else { return VolumeEnvelope() }

        let keepsOriginalHead = outputRange.start <= .zero
        let keepsOriginalTail = originalOutputDuration.isNumeric
            && outputRange.end >= originalOutputDuration
        let ramps = envelope.ramps.compactMap { ramp -> VolumeEnvelope.Ramp? in
            guard ramp.range.start.isNumeric,
                  ramp.range.duration.isNumeric,
                  ramp.range.duration > .zero else { return nil }
            let overlap = ramp.range.intersection(outputRange)
            guard overlap.duration > .zero else { return nil }

            let fullDuration = ramp.range.duration.seconds
            guard fullDuration > 0, fullDuration.isFinite else { return nil }
            let startFraction = Float(max(0, min(1, (overlap.start - ramp.range.start).seconds / fullDuration)))
            let endFraction = Float(max(0, min(1, (overlap.end - ramp.range.start).seconds / fullDuration)))
            let from = ramp.fromVolume + (ramp.toVolume - ramp.fromVolume) * startFraction
            let to = ramp.fromVolume + (ramp.toVolume - ramp.fromVolume) * endFraction
            return VolumeEnvelope.Ramp(
                range: CMTimeRange(start: overlap.start - outputRange.start, duration: overlap.duration),
                fromVolume: from,
                toVolume: to)
        }

        return VolumeEnvelope(
            fadeIn: keepsOriginalHead ? envelope.fadeIn : .zero,
            fadeOut: keepsOriginalTail ? envelope.fadeOut : .zero,
            ramps: ramps)
    }

    private nonisolated static func timelineRange(forSourceRelativeRange range: CMTimeRange,
                                                  in clip: Clip) -> CMTimeRange? {
        guard range.start.isNumeric,
              range.duration.isNumeric,
              range.duration > .zero else { return nil }

        let clipSourceRange = CMTimeRange(start: .zero, duration: clip.duration)
        let clamped = range.intersection(clipSourceRange)
        guard clamped.duration > .zero else { return nil }

        let outputStart = clip.outputOffset(forSourceOffset: clamped.start)
        let outputEnd = clip.outputOffset(forSourceOffset: clamped.end)
        guard outputEnd > outputStart else { return nil }
        return CMTimeRange(start: clip.timelineStart + outputStart,
                           duration: outputEnd - outputStart)
    }
}
