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
        Task { [weak self] in await self?.rebuild() }
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

        // Offset proposal keyframes to clip-source-local time. The proposal
        // keyframes are authored from 0...duration relative to the proposal
        // start. Convert to clip-source-local by subtracting the clip's
        // sourceStart (the in-point within the recording).
        let clip = project.videoTracks[trackIndex].clips[clipIndex]
        let recordingOffset = proposal.timeRange.start - clip.sourceStart
        let offsetKeyframes = proposal.keyframes.map { kf in
            Keyframe<Transform2D>(
                id: kf.id,
                time: kf.time + recordingOffset,
                value: kf.value,
                incomingHandle: kf.incomingHandle,
                outgoingHandle: kf.outgoingHandle)
        }
        // Merge with existing keyframes rather than replacing, so previously
        // applied proposals are preserved.
        let existing = project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes
        let merged = existing.keyframes + offsetKeyframes
        performUndoable("Apply Auto-Zoom Proposal") {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes =
                Keyframed(keyframes: merged, defaultValue: .identity)
        }
        statusMessage = "Applied auto-zoom proposal."
        Task { [weak self] in await self?.rebuild() }
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

        // Merge all proposal keyframes with existing keyframes, offsetting
        // each by its proposal start time minus the clip's sourceStart so
        // they align with clip-source-local time.
        let clip = project.videoTracks[trackIndex].clips[clipIndex]
        var newKeyframes: [Keyframe<Transform2D>] = []
        for proposal in proposals {
            let recordingOffset = proposal.timeRange.start - clip.sourceStart
            for kf in proposal.keyframes {
                newKeyframes.append(Keyframe<Transform2D>(
                    id: kf.id,
                    time: kf.time + recordingOffset,
                    value: kf.value,
                    incomingHandle: kf.incomingHandle,
                    outgoingHandle: kf.outgoingHandle))
            }
        }
        let existing = clip.transformKeyframes
        let merged = existing.keyframes + newKeyframes

        performUndoable("Apply All Auto-Zoom Proposals") {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes =
                Keyframed(keyframes: merged, defaultValue: .identity)
        }
        autoZoomProposals.removeAll()
        statusMessage = "Applied \(proposals.count) auto-zoom proposals."
        Task { [weak self] in await self?.rebuild() }
    }

    /// Import a standalone Phase 43 `events.json` file and generate proposals.
    @MainActor
    func importScreencastEventLog(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let log = try JSONDecoder().decode(ScreencastEventLog.self, from: data)
            guard log.isSupportedSchema else {
                statusMessage = "Event log uses an unsupported schema."
                return
            }
            storeScreencastEventLog(log)
            autoZoomProposals = AutoZoomProposalGenerator.generateProposals(
                from: log,
                canvasSize: project.renderSize)
            markDirty()
            statusMessage = autoZoomProposals.isEmpty
                ? "Imported event log; no auto-zoom proposals found."
                : "Imported event log; \(autoZoomProposals.count) auto-zoom proposals available."
        } catch {
            statusMessage = "Could not import event log: \(error.localizedDescription)"
        }
    }

    @MainActor
    func storeScreencastEventLog(_ log: ScreencastEventLog) {
        project.screencastEventLogs.removeAll { $0.sessionID == log.sessionID }
        project.screencastEventLogs.append(log)
    }

    // MARK: - Padded Background

    /// Apply a default padded background preset.
    @MainActor
    func applyPaddedBackground() {
        performUndoable("Apply Padded Background") {
            project.paddedBackground = PaddedBackgroundPreset()
        }
        statusMessage = "Applied padded background."
        Task { [weak self] in await self?.rebuild() }
    }

    /// Apply an image-backed padded background. The bookmark is persisted for
    /// single-file documents and copied into `.lcbundle` saves.
    @MainActor
    func applyPaddedBackgroundImage(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else {
            statusMessage = "Could not access background image."
            return
        }

        performUndoable("Apply Background Image") {
            var preset = project.paddedBackground ?? PaddedBackgroundPreset()
            preset.source = .image
            preset.imageBookmark = bookmark
            preset.imageBundleRelativePath = nil
            project.paddedBackground = preset
        }
        statusMessage = "Applied \(url.lastPathComponent) as padded background."
        Task { [weak self] in await self?.rebuild() }
    }

    /// Mutate the padded background preset with one undo coalescing target.
    @MainActor
    func updatePaddedBackground(_ transform: @escaping (inout PaddedBackgroundPreset) -> Void) {
        performCoalescedUndoable("Edit Padded Background", target: "padded-background", rebuild: .immediate) {
            var preset = project.paddedBackground ?? PaddedBackgroundPreset()
            transform(&preset)
            project.paddedBackground = preset
        }
    }

    /// Remove the padded background preset.
    @MainActor
    func removePaddedBackground() {
        guard project.paddedBackground != nil else { return }
        performUndoable("Remove Padded Background") {
            project.paddedBackground = nil
        }
        statusMessage = "Removed padded background."
        Task { [weak self] in await self?.rebuild() }
    }
}
