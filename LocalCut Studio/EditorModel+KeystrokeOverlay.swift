import Foundation
import LocalCutCore

// MARK: - Keystroke Overlay (Phase 44)

extension EditorModel {

    /// Creates a keystroke overlay clip from the first available event log.
    @MainActor
    func addKeystrokeOverlayFromEventLog() {
        guard let log = project.screencastEventLogs.first else {
            statusMessage = "No event log available for keystroke overlay."
            return
        }

        guard let clip = KeystrokeOverlayGenerator.generate(from: log) else {
            statusMessage = "No keystroke events found in the event log."
            return
        }

        performUndoable("Add Keystroke Overlay") {
            project.keystrokeOverlayClips.append(clip)
            statusMessage = "Added keystroke overlay with \(clip.events.count) event(s)."
        }
    }

    /// Removes a keystroke overlay clip by ID.
    @MainActor
    func removeKeystrokeOverlay(id: KeystrokeOverlayClip.ID) {
        performUndoable("Remove Keystroke Overlay") {
            project.keystrokeOverlayClips.removeAll { $0.id == id }
            statusMessage = "Removed keystroke overlay."
        }
    }

    /// Updates the style of a keystroke overlay clip.
    @MainActor
    func updateKeystrokeOverlayStyle(id: KeystrokeOverlayClip.ID, style: KeystrokeOverlayStyle) {
        guard let index = project.keystrokeOverlayClips.firstIndex(where: { $0.id == id }) else { return }
        performUndoable("Update Keystroke Overlay Style") {
            project.keystrokeOverlayClips[index].style = style
        }
    }
}
