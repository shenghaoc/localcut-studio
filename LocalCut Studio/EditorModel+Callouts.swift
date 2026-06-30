import Foundation
import CoreMedia
import CoreGraphics
import LocalCutCore

// MARK: - Callout management (Phase 43)

extension EditorModel {

    /// Adds a new callout clip at the current playhead position with a default
    /// duration and the given kind.
    @MainActor
    func addCallout(kind: CalloutKind) {
        let defaultDuration = CMTime(seconds: 3, preferredTimescale: 600)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: currentTime, preferredTimescale: 600),
            duration: defaultDuration)

        // Assign sequential step numbers for step-number callouts.
        let stepNumber: Int
        if kind == .stepNumber {
            let existingSteps = project.callouts.filter { $0.kind == .stepNumber }
            stepNumber = (existingSteps.map(\.stepNumber).max() ?? 0) + 1
        } else {
            stepNumber = 1
        }

        let callout = CalloutClip(kind: kind, timeRange: timeRange, stepNumber: stepNumber)
        performUndoable("Add \(kind.displayName) Callout") {
            project.callouts.append(callout)
        }
        selectedCalloutID = callout.id
        statusMessage = "Added \(kind.displayName.lowercased()) callout."
        Task { await rebuild() }
    }

    /// Removes a callout clip by ID.
    @MainActor
    func removeCallout(id: UUID) {
        guard project.callouts.contains(where: { $0.id == id }) else { return }
        performUndoable("Remove Callout") {
            project.callouts.removeAll { $0.id == id }
            if selectedCalloutID == id {
                selectedCalloutID = nil
            }
        }
        statusMessage = "Removed callout."
        Task { await rebuild() }
    }

    /// Updates a callout clip's properties.
    @MainActor
    func updateCallout(_ updated: CalloutClip) {
        guard let index = project.callouts.firstIndex(where: { $0.id == updated.id }) else { return }
        performCoalescedUndoable("Edit Callout", target: updated.id, rebuild: .immediate) {
            project.callouts[index] = updated
        }
    }

    /// Returns the callout with the given ID, or nil.
    func callout(for id: UUID) -> CalloutClip? {
        project.callouts.first(where: { $0.id == id })
    }
}
