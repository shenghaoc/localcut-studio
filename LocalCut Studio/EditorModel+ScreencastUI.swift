import Foundation
import CoreMedia
import LocalCutCore

// MARK: - Screencast UI integration (Phase 43)

extension EditorModel {

    // MARK: - Zoom-n-Pan Presets

    /// Apply a zoom-n-pan preset to the selected clip's transform keyframes.
    @MainActor
    func applyZoomPanPreset(kind: ZoomPanPresetKind) {
        guard let clipID = selectedClipID,
              let trackIndex = project.videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clipID }) }),
              let clipIndex = project.videoTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID })
        else {
            statusMessage = "Select a video clip to apply a zoom-n-pan preset."
            return
        }

        let clip = project.videoTracks[trackIndex].clips[clipIndex]
        let preset = ZoomPanPreset(kind: kind, duration: clip.duration)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: clip.duration)

        guard !keyframes.isEmpty else {
            statusMessage = "Could not generate keyframes for this preset."
            return
        }

        performUndoable("Apply \(kind.displayName)") {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes =
                Keyframed(keyframes: keyframes, defaultValue: .identity)
        }
        statusMessage = "Applied \(kind.displayName.lowercased()) preset."
        Task { await rebuild() }
    }

    // MARK: - Auto-Zoom Proposals

    /// Whether there are auto-zoom proposals to review.
    var hasAutoZoomProposals: Bool {
        !autoZoomProposals.isEmpty
    }

    /// Apply a single auto-zoom proposal to the selected clip.
    @MainActor
    func applyAutoZoomProposal(_ proposal: ZoomPanProposal) {
        guard let clipID = selectedClipID,
              let trackIndex = project.videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clipID }) }),
              let clipIndex = project.videoTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID })
        else {
            statusMessage = "Select a video clip to apply the proposal."
            return
        }

        performUndoable("Apply Auto-Zoom Proposal") {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes =
                Keyframed(keyframes: proposal.keyframes, defaultValue: .identity)
        }
        statusMessage = "Applied auto-zoom proposal."
        Task { await rebuild() }
    }

    /// Skip (dismiss) an auto-zoom proposal without modifying the timeline.
    @MainActor
    func skipAutoZoomProposal(_ proposal: ZoomPanProposal) {
        autoZoomProposals.removeAll { $0.id == proposal.id }
        statusMessage = "Skipped proposal."
    }

    /// Apply all auto-zoom proposals to the selected clip.
    @MainActor
    func applyAllAutoZoomProposals() {
        guard let clipID = selectedClipID,
              let trackIndex = project.videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clipID }) }),
              let clipIndex = project.videoTracks[trackIndex].clips.firstIndex(where: { $0.id == clipID })
        else {
            statusMessage = "Select a video clip to apply proposals."
            return
        }

        let proposals = autoZoomProposals
        guard !proposals.isEmpty else { return }

        // Merge all proposal keyframes into one set.
        var allKeyframes: [Keyframe<Transform2D>] = []
        for proposal in proposals {
            allKeyframes.append(contentsOf: proposal.keyframes)
        }

        performUndoable("Apply All Auto-Zoom Proposals") {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes =
                Keyframed(keyframes: allKeyframes, defaultValue: .identity)
        }
        autoZoomProposals.removeAll()
        statusMessage = "Applied \(proposals.count) auto-zoom proposals."
        Task { await rebuild() }
    }

    // MARK: - Padded Background

    /// Apply a default padded background preset.
    @MainActor
    func applyPaddedBackground() {
        performUndoable("Apply Padded Background") {
            project.paddedBackground = PaddedBackgroundPreset()
        }
        statusMessage = "Applied padded background."
        Task { await rebuild() }
    }

    /// Remove the padded background preset.
    @MainActor
    func removePaddedBackground() {
        guard project.paddedBackground != nil else { return }
        performUndoable("Remove Padded Background") {
            project.paddedBackground = nil
        }
        statusMessage = "Removed padded background."
        Task { await rebuild() }
    }
}
