import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore

// MARK: - Smart Reframe (Phase 33)

extension EditorModel {

    // MARK: - Computed accessors

    /// The target aspect ratio for the reframe overlay.
    @MainActor
    var reframeTargetAspectRatio: Float {
        reframeOptions.targetAspectRatio
    }

    /// Evaluates the reframe proposal at the current playhead for overlay display.
    @MainActor
    var reframeTransformAtPlayhead: Transform2D? {
        guard let proposal = reframeProposal,
              let clip = selectedClip,
              let localTime = selectedClipTransformLocalPlayheadTime else { return nil }
        let kfTrack = Keyframed<Transform2D>(
            keyframes: proposal.keyframes.map {
                Keyframe(time: $0.time, value: $0.value,
                         incomingHandle: $0.incomingHandle,
                         outgoingHandle: $0.outgoingHandle)
            },
            defaultValue: .identity
        )
        guard kfTrack.isAnimated else { return nil }
        return kfTrack.value(at: localTime)
    }

    // MARK: - Analysis

    /// Starts smart reframe analysis on the selected clip.
    @MainActor
    func runSmartReframeAnalysis() {
        guard let clip = selectedClip,
              let media = project.media(for: clip.mediaID) else {
            statusMessage = "Select a video clip to analyse for smart reframe."
            return
        }
        guard media.hasVideo else {
            statusMessage = "\(media.name) has no video track."
            return
        }

        reframeAnalysisTask?.cancel()
        isReframeAnalyzing = true
        reframeProgressMessage = "Preparing analysis…"
        showReframeOverlay = true

        let asset = media.asset
        let sourceRange = clip.timeRangeInSource
        let sourceSize = media.naturalSize
        let targetSize = project.renderSize
        let options = reframeOptions
        let generation = reframeAnalysisGeneration + 1
        reframeAnalysisGeneration = generation

        reframeAnalysisTask = Task { [weak self] in
            let analyzer = ReframeAnalyzer()
            do {
                let proposal = try await analyzer.analyze(
                    asset: asset,
                    timeRange: sourceRange,
                    sourceSize: sourceSize,
                    targetSize: targetSize,
                    options: options
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.reframeAnalysisGeneration == generation else { return }
                        switch progress {
                        case .preparing:
                            self.reframeProgressMessage = "Preparing analysis…"
                        case .analyzing(let frame, _):
                            self.reframeProgressMessage = "Analyzing frame \(frame)…"
                        case .generatingKeyframes:
                            self.reframeProgressMessage = "Generating keyframes…"
                        case .completed:
                            self.reframeProgressMessage = "Analysis complete."
                        case .cancelled:
                            self.reframeProgressMessage = "Analysis cancelled."
                        case .failed(let msg):
                            self.reframeProgressMessage = "Failed: \(msg)"
                        }
                    }
                }

                guard let self, self.reframeAnalysisGeneration == generation else { return }
                if let proposal {
                    self.reframeProposal = proposal
                    let warningText = proposal.warnings.isEmpty ? "" : " Warnings: \(proposal.warnings.count)."
                    self.statusMessage = "Smart reframe complete: \(proposal.keyframes.count) keyframes, mode: \(proposal.detectionMode.rawValue).\(warningText)"
                }
            } catch is CancellationError {
                // Cancelled — no-op
            } catch {
                guard let self, self.reframeAnalysisGeneration == generation else { return }
                self.statusMessage = "Smart reframe failed: \(error.localizedDescription)"
            }

            guard let self, self.reframeAnalysisGeneration == generation else { return }
            self.isReframeAnalyzing = false
        }
    }

    /// Cancels the current reframe analysis.
    @MainActor
    func cancelSmartReframeAnalysis() {
        reframeAnalysisTask?.cancel()
        reframeAnalysisTask = nil
        isReframeAnalyzing = false
        reframeProgressMessage = "Cancelled."
    }

    // MARK: - Apply / Discard

    /// Applies the current reframe proposal to the selected clip's transform
    /// keyframes in a single undoable transaction.
    @MainActor
    func applySmartReframeProposal() {
        guard let proposal = reframeProposal,
              !proposal.keyframes.isEmpty,
              let clipID = selectedClipID,
              let (trackIndex, clipIndex) = trackAndClipIndex(of: clipID) else {
            statusMessage = "No reframe proposal to apply."
            return
        }

        let newKeyframes = Keyframed<Transform2D>(
            keyframes: proposal.keyframes.map {
                Keyframe(time: $0.time, value: $0.value,
                         incomingHandle: $0.incomingHandle,
                         outgoingHandle: $0.outgoingHandle)
            },
            defaultValue: .identity
        )

        performUndoable("Apply Smart Reframe") {
            project.videoTracks[trackIndex].clips[clipIndex].transformKeyframes = newKeyframes
        }

        reframeProposal = nil
        showReframeOverlay = false
        statusMessage = "Smart reframe applied: \(newKeyframes.keyframes.count) keyframes."
        Task { await rebuild() }
    }

    /// Discards the current reframe proposal without modifying the project.
    @MainActor
    func discardSmartReframeProposal() {
        reframeProposal = nil
        showReframeOverlay = false
        statusMessage = "Smart reframe proposal discarded."
    }

    // MARK: - Options mutation

    @MainActor
    func setReframeTargetAspectRatio(_ ratio: Float) {
        reframeOptions.targetAspectRatio = ratio
    }

    @MainActor
    func setReframeAnalysisFPS(_ fps: Double) {
        reframeOptions.analysisFPS = fps
    }
}
