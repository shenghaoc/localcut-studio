import Foundation
import AVFoundation

// MARK: - Caption track editing

extension EditorModel {

    /// Reads an SRT or VTT file and adds the parsed cues as a new caption track.
    /// All edits flow through the undo system; the import itself is one step.
    func importCaptionTrack(from url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let track = try CaptionImporter.importTrack(from: url)
            performUndoable("Import Captions") {
                project.captionTracks.append(track)
                statusMessage = "Imported \(track.lines.count) caption line(s) from \(url.lastPathComponent)."
                scheduleRebuild()
            }
        } catch {
            statusMessage = "Could not import captions: \(error.localizedDescription)"
        }
    }

    /// Creates an empty caption track with a sensible default name.
    func addEmptyCaptionTrack() {
        performUndoable("Add Caption Track") {
            let name = "C\(project.captionTracks.count + 1)"
            project.captionTracks.append(CaptionTrack(name: name))
            statusMessage = "Added caption track."
            scheduleRebuild()
        }
    }

    /// Removes a caption track and refreshes preview.
    func removeCaptionTrack(id: CaptionTrack.ID) {
        performUndoable("Remove Caption Track") {
            project.captionTracks.removeAll { $0.id == id }
            scheduleRebuild()
        }
    }

    /// Adds a placeholder caption line at the playhead with default duration 2 s.
    func addCaptionLine(in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }) else { return }
        performUndoable("Add Caption Line") {
            let start = CMTime(seconds: currentTime, preferredTimescale: 600)
            let line = CaptionLine(
                range: CMTimeRange(start: start, duration: CMTime(seconds: 2, preferredTimescale: 600)),
                text: "New caption")
            track.addLine(line)
            scheduleRebuild()
        }
    }

    /// Removes one line from a caption track.
    func removeCaptionLine(_ lineID: CaptionLine.ID, in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }) else { return }
        performUndoable("Remove Caption Line") {
            track.removeLine(id: lineID)
            scheduleRebuild()
        }
    }

    /// Updates a line in place; matched by line id.
    func updateCaptionLine(_ updated: CaptionLine, in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }) else { return }
        performUndoable("Edit Caption") {
            track.updateLine(updated)
            scheduleRebuild()
        }
    }

    /// Toggles a caption track's mute through the undo system so it groups with
    /// every other caption edit.
    func setCaptionTrackMuted(_ muted: Bool, in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              track.isMuted != muted else { return }
        performUndoable(muted ? "Mute Caption Track" : "Unmute Caption Track") {
            track.isMuted = muted
            scheduleRebuild()
        }
    }

    /// Updates the default style for a track. Used by the inspector preset picker.
    func updateCaptionTrackDefaultStyle(_ style: CaptionStyle, in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }) else { return }
        performUndoable("Change Caption Style") {
            var clamped = style
            clamped.clamp()
            track.defaultStyle = clamped
            scheduleRebuild()
        }
    }
}
