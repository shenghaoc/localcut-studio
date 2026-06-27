import Foundation
import AVFoundation
import LocalCutCore

final class PreviewRebuildCoordinator {
    nonisolated(unsafe) private var pendingRebuildTask: Task<Void, Never>?
    nonisolated(unsafe) private var activeRebuildTask: Task<Void, Never>?

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
        do {
            let result = try await CompositionBuilder.build(project: model.project, showSkinMask: model.showSkinMask)
            guard !Task.isCancelled else { return }
            guard let built = result else {
                model.replacePreviewItem(with: nil)
                model.totalDuration = 0
                model.isPlaying = false
                DiagnosticsBridge.shared.setDecoderCount(0)
                DiagnosticsBridge.shared.clearRenderSamples()
                return
            }
            let cleanupPreviewActive = built.audioCleanup.requiresOfflineProcessing
                && !built.composition.tracks(withMediaType: .audio).isEmpty
            var cleanupPreviewRunning = false
            if cleanupPreviewActive {
                do {
                    model.audioBus.updateLiveCleanupSettings(model.project.voiceCleanup)
                    try model.audioBus.prepareLiveForPreview()
                    model.audioBus.scheduleLiveComposition(
                        built.composition,
                        audioMix: built.audioMix,
                        startTime: CMTime(seconds: min(resumeAt, built.duration), preferredTimescale: 600),
                        onFailure: { [weak model] message in
                            model?.statusMessage = "Live voice cleanup unavailable: \(message)"
                        })
                    cleanupPreviewRunning = true
                } catch {
                    model.statusMessage = "Live voice cleanup unavailable: \(error.localizedDescription)"
                    model.audioBus.stopLivePreviewAudio()
                }
            } else {
                model.audioBus.stopLivePreviewAudio()
            }

            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = cleanupPreviewRunning
                ? Self.mutedAudioMix(for: built.composition)
                : built.audioMix
            model.replacePreviewItem(with: item)
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
        } catch {
            model.statusMessage = "Preview build failed: \(error.localizedDescription)"
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
