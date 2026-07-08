import Foundation
import CoreGraphics
import CoreMedia
import LocalCutCore

// MARK: - Program landing

/// Handles landing a Program Session result into the project timeline.
/// Creates ISO tracks for recorded sources plus 1 layout track,
/// all in a single undoable transaction.
enum ProgramLanding: Sendable {

    /// Lands a program session result into the project.
    ///
    /// - Parameters:
    ///   - result: The session result from `ProgramSession.stop()`.
    ///   - model: The editor model to land into.
    static func land(result: ProgramSessionResult,
                     model: EditorModel) {
        var mediaItems: [MediaItem] = []
        var videoTracks: [Track] = []
        var audioTracks: [Track] = []
        let endedRecords = result.manifest.endedRecordsBySourceID

        for (sourceID, fileURL) in result.isoTrackURLs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let source = result.manifest.header?.sources.first(where: { $0.id == sourceID })
            let trackName = source?.displayName ?? sourceID.uuidString.prefix(8).description
            guard let duration = mediaDuration(for: sourceID, result: result, endedRecords: endedRecords) else {
                continue
            }
            // Use a fresh UUID for the MediaItem so multiple sessions
            // recording from the same source don't collide.
            let item = MediaItem(url: fileURL, id: UUID())
            item.name = "Program \(trackName)"
            item.captureSourceID = sourceID
            item.duration = duration
            item.wantsBundling = true
            if source?.kind.isVideo == true {
                item.hasVideo = true
                item.naturalSize = CGSize(width: source?.width ?? 1920, height: source?.height ?? 1080)
            } else {
                item.hasAudio = true
            }
            let didAccess = fileURL.startAccessingSecurityScopedResource()
            item.bookmark = try? fileURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            mediaItems.append(item)

            let trackKind: TrackKind = source?.kind.isVideo == true ? .video : .audio
            let track = Track(name: "ISO: \(trackName)", kind: trackKind)
            let clip = Clip(
                mediaID: item.id,
                sourceStart: .zero,
                duration: item.duration,
                timelineStart: timelineStart(for: sourceID, endedRecords: endedRecords))
            track.clips = [clip]
            if trackKind == .video {
                videoTracks.append(track)
            } else {
                audioTracks.append(track)
            }
            model.retainAccess(fileURL, didStart: didAccess)
        }

        // Build layout track from scene-switch records.
        let layoutClips = buildLayoutClips(
            switches: result.sceneSwitches,
            sessionStartHostTimeUs: result.manifest.header?.sessionStartHostTimeUs ?? 0,
            sessionDuration: result.duration)
        let layoutTrack = LayoutTrack(name: "Layout")
        layoutTrack.clips = layoutClips

        // Apply in one undoable transaction.
        model.performUndoable("Land Program Session") {
            model.project.mediaItems.append(contentsOf: mediaItems)
            model.project.videoTracks.append(contentsOf: videoTracks)
            model.project.audioTracks.append(contentsOf: audioTracks)
            model.project.layoutTracks.append(layoutTrack)
            model.scheduleRebuild()
        }
    }

    /// Partitions scene-switch records into segments and creates
    /// `LayoutClip`s. Each segment gets the `SceneDefinition` snapshot
    /// from the resolved scene-doc.
    static func buildLayoutClips(
        switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)],
        sessionStartHostTimeUs: Int64,
        sessionDuration: CMTime
    ) -> [LayoutClip] {
        guard !switches.isEmpty else { return [] }

        var clips: [LayoutClip] = []
        let timescale: CMTimeScale = 600
        let sessionDurationUs = CaptureManifest.microseconds(from: sessionDuration)

        for (index, sw) in switches.enumerated() {
            // Find the scene definition in the resolved scene-doc.
            let sceneDef = sw.sceneDoc.scenes.first(where: { $0.id == sw.sceneId })
                ?? SceneDefinition(name: "Unknown", layers: [])

            // Segment start time.
            let startUs = max(0, sw.atUs - sessionStartHostTimeUs)
            let startTime = CMTime(value: startUs, timescale: CaptureManifest.microsecondTimescale)
                .convertScale(timescale, method: .default)

            // Segment end time: next switch or session end.
            let endTime: CMTime
            if index + 1 < switches.count {
                let nextUs = max(0, switches[index + 1].atUs - sessionStartHostTimeUs)
                endTime = CMTime(value: nextUs, timescale: CaptureManifest.microsecondTimescale)
                    .convertScale(timescale, method: .default)
            } else {
                endTime = CMTime(value: sessionDurationUs, timescale: CaptureManifest.microsecondTimescale)
                    .convertScale(timescale, method: .default)
            }

            let duration = CMTimeSubtract(endTime, startTime)
            guard duration.isValid, duration.seconds >= 0 else { continue }

            let clip = LayoutClip(
                timelineStart: CMTimeCode(CMTime(value: startTime.value, timescale: timescale)),
                duration: CMTimeCode(CMTime(value: duration.value, timescale: timescale)),
                sceneSnapshot: sceneDef)
            clips.append(clip)
        }

        return clips
    }

    private static func mediaDuration(
        for sourceID: UUID,
        result: ProgramSessionResult,
        endedRecords: [UUID: [CaptureSourceEndedRecord]]
    ) -> CMTime? {
        if let ended = endedRecords[sourceID]?.first {
            guard ended.durationUs > 0, ended.sampleCount > 0 else {
                return nil
            }
            return CaptureManifest.time(fromMicroseconds: ended.durationUs)
        }
        // Recovered Program Mode sessions may have readable fragmented movie
        // files but no source-ended records. In that case, use the recovered
        // session duration rather than dropping the source.
        return result.duration > .zero ? result.duration : nil
    }

    private static func timelineStart(
        for sourceID: UUID,
        endedRecords: [UUID: [CaptureSourceEndedRecord]]
    ) -> CMTime {
        guard let startUs = endedRecords[sourceID]?.first?.timelineStartUs else {
            return .zero
        }
        return CaptureManifest.time(fromMicroseconds: startUs)
    }
}
