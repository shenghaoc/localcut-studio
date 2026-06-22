import Foundation
import AVFoundation

// MARK: - Marker editing

extension EditorModel {

    /// The currently selected marker, looked up against the project's list.
    var selectedMarker: TimelineMarker? {
        guard let id = selectedMarkerID else { return nil }
        return project.markers.first { $0.id == id }
    }

    /// Adds a marker at the playhead and selects it. The list stays sorted by
    /// `time` so the timeline ruler and inspector can iterate it in order.
    func addMarkerAtPlayhead() {
        performUndoable("Add Marker") {
            let time = CMTime(seconds: currentTime, preferredTimescale: 600)
            let marker = TimelineMarker(time: time, name: defaultMarkerName())
            insertMarkerSorted(marker)
            selectedMarkerID = marker.id
            statusMessage = "Added marker at \(TimeFormatting.timecode(time.seconds))."
        }
    }

    /// Removes the marker with the given id. Clears the selection if it was
    /// the selected one.
    func removeMarker(id: TimelineMarker.ID) {
        guard project.markers.contains(where: { $0.id == id }) else { return }
        performUndoable("Remove Marker") {
            project.markers.removeAll { $0.id == id }
            if selectedMarkerID == id { selectedMarkerID = nil }
        }
    }

    /// Renames a marker; routes through `performUndoable` so a Shift+M popover
    /// rename folds into one undo step at submit.
    func renameMarker(id: TimelineMarker.ID, to name: String) {
        guard let index = project.markers.firstIndex(where: { $0.id == id }),
              project.markers[index].name != name else { return }
        performUndoable("Rename Marker") {
            project.markers[index].name = name
        }
    }

    /// Coalesced rename / recolour for a continuous gesture (inspector typing,
    /// future colour-picker drag). Keyed on the marker id so two adjacent
    /// edits on different markers don't fold into one undo step.
    func updateMarkerCoalesced(id: TimelineMarker.ID,
                               name: String? = nil,
                               colour: RGBAColour? = nil) {
        guard let index = project.markers.firstIndex(where: { $0.id == id }) else { return }
        performCoalescedUndoable("Edit Marker", target: id, rebuild: .skip) {
            if let name { project.markers[index].name = name }
            if let colour { project.markers[index].colour = colour }
        }
    }

    /// Seeks the playhead to a marker's time. Cheap helper for click-to-seek
    /// in the inspector list.
    func seekToMarker(id: TimelineMarker.ID) {
        guard let marker = project.markers.first(where: { $0.id == id }) else { return }
        seek(toSeconds: marker.time.seconds)
        selectedMarkerID = id
    }

    // MARK: - Helpers

    /// Inserts a marker so the array stays sorted by `time`. Two markers at the
    /// exact same time are allowed (they're distinct by id) and order is stable.
    private func insertMarkerSorted(_ marker: TimelineMarker) {
        if let i = project.markers.firstIndex(where: { $0.time > marker.time }) {
            project.markers.insert(marker, at: i)
        } else {
            project.markers.append(marker)
        }
    }

    /// "Marker", "Marker 2", "Marker 3", … so two consecutive M presses don't
    /// produce two identically-labelled glyphs on the ruler.
    private func defaultMarkerName() -> String {
        let base = "Marker"
        let existing = Set(project.markers.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
