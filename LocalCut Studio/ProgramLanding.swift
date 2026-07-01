import Foundation
import CoreMedia
import LocalCutCore

// MARK: - Program landing

/// Handles landing a Program Session result into the project timeline.
/// Creates N ISO tracks (one per video source) plus 1 layout track,
/// all in a single undoable transaction.
enum ProgramLanding {

    /// Lands a program session result into the project.
    ///
    /// - Parameters:
    ///   - result: The session result from `ProgramSession.stop()`.
    ///   - model: The editor model to land into.
    ///   - scenes: The scenes that were active during the session (from
    ///     the latest preceding scene-doc snapshot, NOT the user's
    ///     current scenes).
    static func land(result: ProgramSessionResult,
                     model: EditorModel,
                     scenes: [SceneDefinition]) {
        let before = model.captureState()

        // Build ISO tracks: one per video source.
        var isoTracks: [Track] = []
        for (sourceID, fileURL) in result.isoTrackURLs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let source = result.manifest.header?.sources.first(where: { $0.id == sourceID })
            let trackName = source?.displayName ?? sourceID.uuidString.prefix(8).description
            let track = Track(name: "ISO: \(trackName)", kind: .video)
            // Create a clip spanning the full session duration from the ISO file.
            let clip = Clip(
                mediaID: sourceID, // Will be resolved during import.
                sourceStart: .zero,
                duration: result.duration,
                timelineStart: .zero)
            track.clips = [clip]
            isoTracks.append(track)
        }

        // Build layout track from scene-switch records.
        let layoutClips = buildLayoutClips(
            switches: result.sceneSwitches,
            sessionDuration: result.duration,
            scenes: scenes)
        let layoutTrack = LayoutTrack(name: "Layout")
        layoutTrack.clips = layoutClips

        // Apply in one undoable transaction.
        model.performUndoable("Land Program Session") {
            model.project.videoTracks.append(contentsOf: isoTracks)
            model.project.layoutTracks.append(layoutTrack)
        }
    }

    /// Partitions scene-switch records into segments and creates
    /// `LayoutClip`s. Each segment gets the `SceneDefinition` snapshot
    /// from the resolved scene-doc.
    static func buildLayoutClips(
        switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)],
        sessionDuration: CMTime,
        scenes: [SceneDefinition]
    ) -> [LayoutClip] {
        guard !switches.isEmpty else { return [] }

        var clips: [LayoutClip] = []
        let timescale: CMTimeScale = 600

        for (index, sw) in switches.enumerated() {
            // Find the scene definition in the resolved scene-doc.
            let sceneDef = sw.sceneDoc.scenes.first(where: { $0.id == sw.sceneId })
                ?? SceneDefinition(name: "Unknown", layers: [])

            // Segment start time.
            let startUs = sw.atUs
            let startTime = CMTime(value: startUs, timescale: CaptureManifest.microsecondTimescale)
                .convertScale(timescale, method: .default)

            // Segment end time: next switch or session end.
            let endTime: CMTime
            if index + 1 < switches.count {
                let nextUs = switches[index + 1].atUs
                endTime = CMTime(value: nextUs, timescale: CaptureManifest.microsecondTimescale)
                    .convertScale(timescale, method: .default)
            } else {
                endTime = sessionDuration.convertScale(timescale, method: .default)
            }

            let duration = CMTimeSubtract(endTime, startTime)
            guard duration.isValid, !duration.isNegative else { continue }

            let clip = LayoutClip(
                timelineStart: CMTimeCode(value: startTime.value, timescale: timescale),
                duration: CMTimeCode(value: duration.value, timescale: timescale),
                sceneSnapshot: sceneDef)
            clips.append(clip)
        }

        return clips
    }
}
