import Foundation
import AVFoundation
import LocalCutCore

final class PreviewRebuildCoordinator {
    /// Pending debounced rebuild task.
    ///
    /// **Isolation invariant:** Set/cancelled on `@MainActor` in
    /// `rebuildDebounced`; also cancelled from the nonisolated `cancelAll()`.
    /// `cancelAll()` is called from teardown paths that are serialized with
    /// rebuild scheduling by the document lifecycle; the unsynchronized
    /// `Task?` pointer access is safe under that caller confinement.
    nonisolated(unsafe) private var pendingRebuildTask: Task<Void, Never>?
    /// Active in-flight rebuild task.
    ///
    /// **Isolation invariant:** Same as `pendingRebuildTask`.
    nonisolated(unsafe) private var activeRebuildTask: Task<Void, Never>?
    private var inFlightPreviewOverlaySourceRegistryIDs = Set<UUID>()

    nonisolated
    func cancelAll() {
        pendingRebuildTask?.cancel()
        activeRebuildTask?.cancel()
        pendingRebuildTask = nil
        activeRebuildTask = nil
    }

    @MainActor
    func rebuildDebounced(after delay: Duration = .milliseconds(200), model: EditorModel) {
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { @MainActor [weak model] in
            try? await Task.sleep(for: delay)
            guard let model, !Task.isCancelled else { return }
            model.scheduleRebuild()
        }
    }

    @MainActor
    func scheduleRebuild(model: EditorModel) {
        activeRebuildTask?.cancel()
        activeRebuildTask = Task { @MainActor [weak model] in
            await model?.rebuild()
        }
    }

    @MainActor
    func rebuild(model: EditorModel) async {
        let resumeAt = model.currentTime
        let overlaySourceRegistryID = await model.registerOverlaySources(purpose: .preview)
        if let overlaySourceRegistryID {
            inFlightPreviewOverlaySourceRegistryIDs.insert(overlaySourceRegistryID)
        }
        var didInstallOverlaySourceRegistry = false
        defer {
            if let overlaySourceRegistryID {
                inFlightPreviewOverlaySourceRegistryIDs.remove(overlaySourceRegistryID)
            }
            if !didInstallOverlaySourceRegistry {
                EffectCompositor.releaseOverlaySources(for: overlaySourceRegistryID)
            }
        }
        do {
            // Register overlay frame sources before building the composition
            // so the compositor can decode overlay frames during rendering.
            let result = try await CompositionBuilder.build(
                project: model.project,
                showSkinMask: model.showSkinMask,
                overlaySourceRegistryID: overlaySourceRegistryID)
            guard !Task.isCancelled else { return }
            guard let built = result else {
                model.replacePreviewItem(with: nil)
                model.totalDuration = 0
                model.isPlaying = false
                DiagnosticsBridge.shared.setDecoderCount(0)
                DiagnosticsBridge.shared.clearRenderSamples()
                return
            }
            let hasAudio = !built.composition.tracks(withMediaType: .audio).isEmpty
            let needsDSPPipeline = built.audioCleanup.requiresOfflineProcessing && hasAudio
            let needsLoudnessGain = built.audioCleanup.loudnessGainLinear != 1.0 && hasAudio
            var cleanupPreviewRunning = false
            if needsDSPPipeline {
                // DSP inserts (denoiser, gate, compressor, limiter) require the
                // full offline pipeline to decode, process, and schedule audio.
                do {
                    // Cancel any previous scheduled audio and restore mixer
                    // unity before VoiceCleanupDSP applies loudness itself.
                    model.audioBus.stopLivePreviewAudio()
                    model.audioBus.updateLiveCleanupSettings(model.project.voiceCleanup)
                    try model.audioBus.prepareLiveForPreview()
                    model.audioBus.scheduleLiveComposition(
                        built.composition,
                        audioMix: built.audioMix,
                        startTime: CMTime(seconds: min(resumeAt, built.duration), preferredTimescale: 600),
                        onFailure: { [weak model] message in
                            model?.statusMessage = EditorModel.failureStatusMessage(
                                summary: "Live voice cleanup unavailable",
                                detail: message,
                                recoverySuggestion: "Export to apply voice cleanup offline.")
                        })
                    cleanupPreviewRunning = true
                } catch {
                    model.statusMessage = EditorModel.failureStatusMessage(
                        summary: "Live voice cleanup unavailable",
                        detail: error.localizedDescription,
                        recoverySuggestion: "Export to apply voice cleanup offline.")
                    model.audioBus.stopLivePreviewAudio()
                }
            } else if needsLoudnessGain {
                // Loudness-only: apply gain through the mixer node volume.
                // No need for the full offline pipeline — just start the live
                // engine for metering and set the mixer output volume.
                // Stop a previous DSP player first so processed audio cannot
                // overlap the unmuted AVPlayerItem path.
                model.audioBus.stopLivePreviewAudio()
                model.audioBus.prepareLive()
                model.audioBus.applyLoudnessGain(built.audioCleanup.loudnessGainLinear)
            } else {
                model.audioBus.stopLivePreviewAudio()
            }

            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = cleanupPreviewRunning
                ? Self.mutedAudioMix(for: built.composition)
                : built.audioMix
            model.replacePreviewItem(with: item, overlaySourceRegistryID: overlaySourceRegistryID)
            didInstallOverlaySourceRegistry = true
            if let overlaySourceRegistryID {
                inFlightPreviewOverlaySourceRegistryIDs.remove(overlaySourceRegistryID)
            }
            EffectCompositor.releaseInactivePreviewOverlaySources(
                keeping: model.activeOverlaySourceRegistryID,
                excluding: inFlightPreviewOverlaySourceRegistryIDs)
            model.totalDuration = built.duration
            DiagnosticsBridge.shared.setDecoderCount(
                built.composition.tracks(withMediaType: .video).count)

            await model.player.seek(
                to: CMTime(seconds: min(resumeAt, built.duration), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero)
            if model.isPlaying {
                model.player.play()
                if cleanupPreviewRunning {
                    model.audioBus.resumeLivePreview()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            model.statusMessage = EditorModel.failureStatusMessage(
                summary: "Preview build failed",
                detail: error.localizedDescription,
                recoverySuggestion: "Check that all media files are still accessible and not corrupted.")
        }
    }

    private static func mutedAudioMix(for composition: AVComposition) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = composition.tracks(withMediaType: .audio).map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(0, at: .zero)
            return parameters
        }
        return mix
    }
}
