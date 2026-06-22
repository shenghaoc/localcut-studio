import Foundation
import AVFoundation

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
