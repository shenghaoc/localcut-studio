import Foundation
import AVFoundation
import LocalCutCore

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
            var settings = project.voiceCleanup
            mutate(&settings)
            settings.clamp()
            project.voiceCleanup = settings
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
            statusMessage = "Measured \(String(format: "%.1f", result.measuredLUFS)) LUFS; applying \(String(format: "%+.1f", result.gainDB)) dB."
        } else {
            statusMessage = "Loudness could not be measured."
        }
    }

    func measureCurrentProjectLoudness() {
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

        statusMessage = "Measuring loudness…"
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let built = try await CompositionBuilder.build(project: project, showSkinMask: showSkinMask) else {
                    applyLoudnessAnalysis(LoudnessAnalysisResult(
                        measuredLUFS: -.infinity,
                        targetLUFS: project.voiceCleanup.loudness.targetLUFS,
                        gainDB: 0,
                        durationSeconds: 0,
                        note: "Normalisation skipped: project has no renderable audio."))
                    return
                }
                let result = try VoiceCleanupAudioProcessing.measureLoudness(
                    composition: built.composition,
                    audioMix: built.audioMix,
                    duration: built.duration,
                    settings: project.voiceCleanup)
                applyLoudnessAnalysis(result)
            } catch {
                statusMessage = "Loudness measurement failed: \(error.localizedDescription)"
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
