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

    /// Runs silence detection on the first selected audio track's media.
    @MainActor
    func runSilenceDetection(parameters: SilenceDetectionParameters = SilenceDetectionParameters()) {
        guard let track = project.audioTracks.first(where: { !$0.clips.isEmpty }),
              let clip = track.clips.first,
              let media = project.media(for: clip.mediaID)
        else {
            statusMessage = "No audio track with media for silence detection."
            return
        }

        let url = media.url
        let params = parameters

        Task {
            do {
                let detector = SilenceDetector()
                let (silences, proposals) = try await detector.detect(url: url, parameters: params)

                await MainActor.run {
                    self.silenceProposals = proposals
                    if silences.isEmpty {
                        self.statusMessage = "No silences detected."
                    } else {
                        self.statusMessage = "Found \(silences.count) silence(s). Review to apply."
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Silence detection failed: \(error.localizedDescription)"
                }
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
            $0.silenceRange.start > $1.silenceRange.start
        }
        guard !selected.isEmpty else {
            statusMessage = "No proposals selected."
            return
        }

        performUndoable("Remove Silences") {
            for proposal in selected {
                applySingleProposal(proposal)
            }
            statusMessage = "Applied \(selected.count) silence cut(s)."
            scheduleRebuild()
        }

        silenceProposals = []
    }

    /// Cancels the review, discarding all proposals.
    @MainActor
    func cancelSilenceReview() {
        silenceProposals = []
        statusMessage = "Silence review cancelled."
    }

    // MARK: - Private

    /// Applies a single proposal by ripple-deleting the silence range.
    ///
    /// Clips overlapping the silence are split; clips entirely after it are
    /// shifted left so no gap remains. Also ripples caption tracks.
    private func applySingleProposal(_ proposal: ProposedCut) {
        let silenceStart = proposal.silenceRange.start
        let silenceEnd = proposal.silenceRange.end
        let silenceDuration = silenceEnd - silenceStart

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
                    newClips.append(left)
                }

                // Right portion (after silence) — shifted left.
                // Use Clip init to get a fresh UUID, avoiding duplicate IDs.
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
                        transition: clip.transition,
                        volumeEnvelope: clip.volumeEnvelope,
                        transformKeyframes: clip.transformKeyframes,
                        speedCurve: clip.speedCurve,
                        preservePitch: clip.preservePitch,
                        pitchAlgorithm: clip.pitchAlgorithm)
                    newClips.append(right)
                }
            }
            track.clips = newClips
        }

        // Ripple caption tracks: shift caption lines that start after the silence.
        for captionTrack in project.captionTracks {
            for line in captionTrack.lines {
                if line.range.start >= silenceEnd {
                    // Caption lines are value types; we need to update in place.
                    // Since CaptionLine.range is a CMTimeRange, shift the line.
                    let shiftedStart = line.range.start - silenceDuration
                    let shiftedRange = CMTimeRange(start: shiftedStart, duration: line.range.duration)
                    captionTrack.updateLine(CaptionLine(
                        id: line.id,
                        range: shiftedRange,
                        text: line.text,
                        words: line.words,
                        style: line.style,
                        styleKeyframes: line.styleKeyframes))
                }
            }
        }
    }
}
