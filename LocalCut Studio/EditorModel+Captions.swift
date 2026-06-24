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

    // MARK: - Caption style keyframes

    func captionStyleLocalPlayheadTime(_ lineID: CaptionLine.ID,
                                       in trackID: CaptionTrack.ID) -> CMTime? {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }) else { return nil }
        let absolute = CMTime(seconds: currentTime, preferredTimescale: 600)
        guard line.range.containsTime(absolute) else { return nil }
        return CMTimeMaximum(absolute - line.range.start, .zero)
    }

    func captionStyleKeyframeValues(_ lineID: CaptionLine.ID,
                                    in trackID: CaptionTrack.ID) -> CaptionStyleKeyframeValues {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }) else {
            return CaptionStyleKeyframeValues(baseStyle: .identity)
        }
        let baseStyle = line.style ?? track.defaultStyle
        guard let keyframes = line.styleKeyframes else {
            return CaptionStyleKeyframeValues(baseStyle: baseStyle)
        }
        let localTime = captionStyleLocalPlayheadTime(lineID, in: trackID) ?? .zero
        let resolvedTime = nearestCaptionStyleKeyframeTime(to: localTime, in: keyframes) ?? localTime
        return keyframes.values(at: resolvedTime)
    }

    func captionStyleKeyframeCount(_ lineID: CaptionLine.ID,
                                   in trackID: CaptionTrack.ID) -> Int {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }) else { return 0 }
        return line.styleKeyframes?.keyframeCount ?? 0
    }

    func hasCaptionStyleKeyframeAtPlayhead(_ lineID: CaptionLine.ID,
                                           in trackID: CaptionTrack.ID) -> Bool {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }),
              let localTime = captionStyleLocalPlayheadTime(lineID, in: trackID) else { return false }
        guard let keyframes = line.styleKeyframes else { return false }
        return nearestCaptionStyleKeyframeTime(to: localTime, in: keyframes) != nil
    }

    func setCaptionStyleKeyframeValues(_ values: CaptionStyleKeyframeValues,
                                       lineID: CaptionLine.ID,
                                       in trackID: CaptionTrack.ID,
                                       coalesced: Bool = true) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }),
              let localTime = captionStyleLocalPlayheadTime(lineID, in: trackID) else {
            statusMessage = "Move the playhead over the caption line to edit animated style."
            return
        }
        let mutation = {
            var updated = line
            var keyframes = updated.styleKeyframes
                ?? CaptionStyleKeyframes(baseStyle: updated.style ?? track.defaultStyle)
            let resolvedTime = self.nearestCaptionStyleKeyframeTime(to: localTime, in: keyframes) ?? localTime
            keyframes.addOrUpdateKeyframes(at: resolvedTime, values: values)
            updated.styleKeyframes = keyframes
            track.updateLine(updated)
        }
        if coalesced {
            performCoalescedUndoable("Animate Caption Style", target: lineID,
                                     rebuild: .debounced, mutate: mutation)
        } else {
            performUndoable("Animate Caption Style") {
                mutation()
                scheduleRebuild()
            }
        }
    }

    func removeCaptionStyleKeyframeAtPlayhead(_ lineID: CaptionLine.ID,
                                              in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }),
              let localTime = captionStyleLocalPlayheadTime(lineID, in: trackID),
              var keyframes = line.styleKeyframes,
              let resolvedTime = nearestCaptionStyleKeyframeTime(to: localTime, in: keyframes) else {
            statusMessage = "No caption style keyframe at the playhead."
            return
        }
        performUndoable("Remove Caption Style Keyframe") {
            var updated = line
            keyframes.removeKeyframes(at: resolvedTime)
            updated.styleKeyframes = keyframes.isEmpty ? nil : keyframes
            track.updateLine(updated)
            scheduleRebuild()
        }
    }

    func clearCaptionStyleKeyframes(_ lineID: CaptionLine.ID,
                                    in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }),
              line.styleKeyframes != nil else { return }
        performUndoable("Clear Caption Style Keyframes") {
            var updated = line
            updated.styleKeyframes = nil
            track.updateLine(updated)
            scheduleRebuild()
        }
    }

    func seekToPreviousCaptionStyleKeyframe(_ lineID: CaptionLine.ID,
                                            in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }),
              let localTime = captionStyleLocalPlayheadTime(lineID, in: trackID) else { return }
        let tolerance = captionStyleKeyframeHitToleranceSeconds
        guard let previous = line.styleKeyframes?.allKeyframeTimes.last(where: {
            $0.seconds < localTime.seconds - tolerance
        }) else { return }
        seek(toSeconds: (line.range.start + previous).seconds)
    }

    func seekToNextCaptionStyleKeyframe(_ lineID: CaptionLine.ID,
                                        in trackID: CaptionTrack.ID) {
        guard let track = project.captionTracks.first(where: { $0.id == trackID }),
              let line = track.lines.first(where: { $0.id == lineID }),
              let localTime = captionStyleLocalPlayheadTime(lineID, in: trackID) else { return }
        let tolerance = captionStyleKeyframeHitToleranceSeconds
        guard let next = line.styleKeyframes?.allKeyframeTimes.first(where: {
            $0.seconds > localTime.seconds + tolerance
        }) else { return }
        seek(toSeconds: (line.range.start + next).seconds)
    }

    private var captionStyleKeyframeHitToleranceSeconds: Double {
        0.5 / max(1, project.frameRate)
    }

    private func nearestCaptionStyleKeyframeTime(to time: CMTime,
                                                 in keyframes: CaptionStyleKeyframes) -> CMTime? {
        let tolerance = captionStyleKeyframeHitToleranceSeconds
        return keyframes.allKeyframeTimes
            .map { candidate in (candidate, abs((candidate - time).seconds)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }
}
