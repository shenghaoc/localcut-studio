import Foundation
import AVFoundation
import LocalCutCore
import LocalCutPlatform

// MARK: - Audio master bus editing (P16)
//
// Mutators that route through the existing `performUndoable` /
// `performCoalescedUndoable` machinery so master-bus edits join the same undo
// stack as every other project mutation. The runtime engine (`audioBus`) lives
// on `EditorModel`; the persistent parameters live on `Project`.

extension EditorModel {

    /// Sets the project's master gain. Slider-drag callers pass `coalesced: true`
    /// so a gesture folds into one undo step labelled "Adjust Master Gain";
    /// reset / numeric entry uses the discrete path.
    func setMasterGain(_ linear: Float, coalesced: Bool = false) {
        let clamped = max(0, min(2, linear))
        if coalesced {
            performCoalescedUndoable("Adjust Master Gain",
                                     target: AnyHashable("audio.master.gain"),
                                     rebuild: .debounced) {
                project.masterGain = clamped
            }
        } else {
            performUndoable("Adjust Master Gain") {
                project.masterGain = clamped
                scheduleRebuild()
            }
        }
    }

    /// Sets one track's input pan / gain on the bus.
    func setTrackInput(_ input: TrackInput, coalesced: Bool = false) {
        var clamped = input
        clamped.clamp()
        let target = AnyHashable("audio.trackInput.\(clamped.id.uuidString)")
        if coalesced {
            performCoalescedUndoable("Adjust Track Audio",
                                     target: target,
                                     rebuild: .debounced) {
                applyTrackInput(clamped)
            }
        } else {
            performUndoable("Adjust Track Audio") {
                applyTrackInput(clamped)
                scheduleRebuild()
            }
        }
    }

    private func applyTrackInput(_ input: TrackInput) {
        if let i = project.trackInputs.firstIndex(where: { $0.id == input.id }) {
            project.trackInputs[i] = input
        } else {
            project.trackInputs.append(input)
        }
    }

    /// Updates the Phase 36 voice-cleanup insert settings. Continuous slider
    /// gestures use the coalesced path; toggles and preset changes use the
    /// discrete path.
    func updateVoiceCleanup(_ name: String = "Adjust Voice Cleanup",
                            coalesced: Bool = false,
                            target: AnyHashable = AnyHashable("audio.voiceCleanup"),
                            mutate: (inout VoiceCleanupSettings) -> Void) {
        let apply: () -> Void = { [self] in
            let wasDSPActive = project.voiceCleanup.requiresOfflineProcessing
            let previousLoudnessGain = project.voiceCleanup.loudnessGainLinear
            var settings = project.voiceCleanup
            mutate(&settings)
            settings.clamp()
            project.voiceCleanup = settings
            audioBus.updateLiveCleanupSettings(settings)
            // Loudness-only gain is baked into the composition audio mix, so
            // every gain-value change needs a rebuild, not just enable/disable.
            let isDSPActive = settings.requiresOfflineProcessing
            if wasDSPActive != isDSPActive
                || previousLoudnessGain != settings.loudnessGainLinear {
                scheduleRebuild()
            }
        }
        if coalesced {
            performCoalescedUndoable(name, target: target, rebuild: .skip, mutate: apply)
        } else {
            performUndoable(name, mutate: apply)
        }
    }

    func applyLoudnessAnalysis(_ result: LoudnessAnalysisResult) {
        updateVoiceCleanup("Apply Loudness Normalisation") { settings in
            settings.loudness.enabled = result.gainDB != 0
            settings.loudness.measuredLUFS = result.measuredLUFS.isFinite ? result.measuredLUFS : nil
            settings.loudness.appliedGainDB = result.gainDB
            settings.loudness.statusNote = result.note
        }
        if let note = result.note {
            statusMessage = note
        } else if result.measuredLUFS.isFinite {
            statusMessage = "Loudness measured at \(String(format: "%.1f", result.measuredLUFS)) LUFS. Applying \(String(format: "%+.1f", result.gainDB)) dB gain."
        } else {
            statusMessage = "Loudness could not be measured. The project may be too short or have no renderable audio."
        }
    }

    /// Discards any in-flight loudness measurement by advancing the token, so a
    /// result computed against a now-changed project is ignored before it can be
    /// applied. Called from the central edit and document-load paths.
    func invalidateLoudnessMeasurement() {
        loudnessTask?.cancel()
        loudnessTask = nil
        loudnessMeasurementToken &+= 1
    }

    func measureCurrentProjectLoudness() {
        // Cancel any prior measurement before handling the new request, including
        // the short-duration path below.
        invalidateLoudnessMeasurement()
        let duration = project.duration.seconds
        guard duration >= 3 else {
            applyLoudnessAnalysis(LoudnessAnalysisResult(
                measuredLUFS: -.infinity,
                targetLUFS: project.voiceCleanup.loudness.targetLUFS,
                gainDB: 0,
                durationSeconds: max(0, duration),
                note: "Normalisation skipped: selection is shorter than 3 seconds."))
            return
        }

        // Remember which generation this run belongs to; stale results are
        // dropped at the apply site below.
        let token = loudnessMeasurementToken
        statusMessage = "Measuring loudness…"
        loudnessTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let built = try await CompositionBuilder.build(
                    project: project,
                    showSkinMask: showSkinMask,
                    includeLoudnessGainInAudioMix: false) else {
                    guard token == loudnessMeasurementToken else { return }
                    applyLoudnessAnalysis(LoudnessAnalysisResult(
                        measuredLUFS: -.infinity,
                        targetLUFS: project.voiceCleanup.loudness.targetLUFS,
                        gainDB: 0,
                        durationSeconds: 0,
                        note: "Normalisation skipped: project has no renderable audio."))
                    return
                }
                // `measureLoudness` decodes and DSP-processes the whole project
                // synchronously, so keep it off the main actor to avoid freezing
                // the UI during measurement. The composition is a freshly-built
                // local value consumed only by this detached task, so confining
                // it with `nonisolated(unsafe)` is sound under Swift 6 (mirrors
                // the writer path in RenderQueue).
                let settings = project.voiceCleanup
                let duration = built.duration
                nonisolated(unsafe) let composition = built.composition
                nonisolated(unsafe) let audioMix = built.audioMix
                let worker = Task.detached(priority: .userInitiated) {
                    try VoiceCleanupAudioProcessing.measureLoudness(
                        composition: composition,
                        audioMix: audioMix,
                        duration: duration,
                        settings: settings)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                // Drop the result if the project moved on while we measured.
                guard token == loudnessMeasurementToken else { return }
                loudnessTask = nil
                applyLoudnessAnalysis(result)
            } catch is CancellationError {
                guard token == loudnessMeasurementToken else { return }
                loudnessTask = nil
            } catch {
                guard token == loudnessMeasurementToken else { return }
                loudnessTask = nil
                statusMessage = Self.failureStatusMessage(
                    summary: "Loudness measurement failed",
                    detail: error.localizedDescription,
                    recoverySuggestion: "Check that the project's audio files are still accessible, then try again.")
            }
        }
    }

    /// Replaces the volume envelope on a clip. Drag gestures fold via the
    /// coalesced path; discrete edits (preset / reset) take the immediate path.
    func setClipVolumeEnvelope(_ envelope: VolumeEnvelope, clipID: Clip.ID,
                               coalesced: Bool = false) {
        let target = AnyHashable("audio.clip.envelope.\(clipID.uuidString)")
        let mutate: () -> Void = { [self] in
            for track in project.videoTracks + project.audioTracks {
                guard let i = track.clips.firstIndex(where: { $0.id == clipID }) else { continue }
                track.clips[i].volumeEnvelope = envelope
                return
            }
        }
        if coalesced {
            performCoalescedUndoable("Adjust Clip Volume",
                                     target: target,
                                     rebuild: .debounced,
                                     mutate: mutate)
        } else {
            performUndoable("Adjust Clip Volume") {
                mutate()
                scheduleRebuild()
            }
        }
    }
}
