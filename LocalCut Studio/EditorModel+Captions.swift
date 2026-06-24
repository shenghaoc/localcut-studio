import Foundation
import AVFoundation

// MARK: - Caption track editing

extension EditorModel {

    /// Reads an SRT or VTT file and adds the parsed cues as a new caption track.
    /// File IO + parsing run on a detached task so a large subtitle file doesn't
    /// stall the UI; the model mutation hops back to the main actor inside the
    /// undoable block. Security-scoped access is held for the whole operation.
    func importCaptionTrack(from url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let isVTT = url.pathExtension.lowercased() == "vtt"
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let lines = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                return try CaptionImporter.parseLines(data: data, isVTT: isVTT)
            }.value
            performUndoable("Import Captions") {
                let track = CaptionTrack(name: name, lines: lines)
                project.captionTracks.append(track)
                statusMessage = "Imported \(lines.count) caption line(s) from \(url.lastPathComponent)."
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

    /// Updates a line in place; matched by line id. Coalesced + debounced so a
    /// run of keystrokes against the same line folds into one undo step and one
    /// composition rebuild — typing per-character through `performUndoable`
    /// would otherwise flood the stack and stall preview.
    func updateCaptionLine(_ updated: CaptionLine, in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }) else { return }
        performCoalescedUndoable("Edit Caption", target: updated.id, rebuild: .debounced) {
            track.updateLine(updated)
        }
    }

    /// Retimes a caption line through the same sorted update path as text edits.
    /// Captions are authored in the effective/rendered timeline space, not in a
    /// clip's pre-transition authored space.
    func retimeCaptionLine(_ lineID: CaptionLine.ID,
                           in trackID: CaptionTrack.ID,
                           start: CMTime? = nil,
                           duration: CMTime? = nil) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }) else { return }
        var updated = line
        let oldStart = line.range.start
        let newStart = CMTimeMaximum(start ?? oldStart, .zero)
        let minDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, project.frameRate)))
        let newDuration = CMTimeMaximum(duration ?? line.range.duration, minDuration)

        updated.range = CMTimeRange(start: newStart, duration: newDuration)
        if let words = updated.words, newStart != oldStart {
            let delta = newStart - oldStart
            updated.words = words.map { word in
                WordTiming(range: CMTimeRange(start: CMTimeMaximum(word.range.start + delta, .zero),
                                              duration: word.range.duration),
                           word: word.word)
            }
        }
        updateCaptionLine(updated, in: trackID)
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

    /// Renames a caption track. Coalesced + rebuild-skipped so a run of
    /// keystrokes in the inspector folds into one undo step without rebuilding
    /// the composition (the name doesn't affect rendering) — satisfies
    /// feature-caption-tracks R2.6 ("the user can rename it").
    func renameCaptionTrack(_ name: String, in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              track.name != name else { return }
        performCoalescedUndoable("Rename Caption Track", target: trackID, rebuild: .skip) {
            track.name = name
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
