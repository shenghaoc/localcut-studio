import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore

// MARK: - Replay buffer timeline insertion (Phase 46)

extension EditorModel {

    /// Inserts a saved replay clip into the timeline at the current playhead.
    func insertReplayClip(url: URL, duration: CMTime) async {
        await insertReplayClips([
            ReplayBufferSavedClip(
                url: url,
                duration: duration,
                sourceFileURL: url)
        ])
    }

    /// Inserts saved replay sources into the timeline at the current playhead.
    func insertReplayClips(_ savedClips: [ReplayBufferSavedClip]) async {
        let validClips = savedClips.filter { clip in
            clip.duration.isNumeric && clip.duration > .zero && clip.duration.seconds.isFinite
        }
        guard !validClips.isEmpty else {
            statusMessage = "Replay clip has no duration."
            return
        }

        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        var prepared: [(clip: ReplayBufferSavedClip, mediaItem: MediaItem)] = []
        for (index, savedClip) in validClips.enumerated() {
            let mediaItem = await prepareReplayMediaItem(
                savedClip,
                timestamp: timestamp,
                sourceIndex: index,
                sourceCount: validClips.count)
            if mediaItem.hasVideo || mediaItem.hasAudio {
                prepared.append((savedClip, mediaItem))
            }
        }

        guard !prepared.isEmpty else {
            statusMessage = "Replay clip has no readable media."
            return
        }

        let playheadTime = CMTime(seconds: currentTime, preferredTimescale: 600)
        let actionName = prepared.count == 1 ? "Insert Replay Clip" : "Insert Replay Clips"

        performUndoable(actionName) {
            project.mediaItems.append(contentsOf: prepared.map(\.mediaItem))

            for candidate in prepared {
                let timelineStart = playheadTime + candidate.clip.timelineOffset
                if candidate.mediaItem.hasVideo {
                    let videoClip = Clip(
                        mediaID: candidate.mediaItem.id,
                        sourceStart: .zero,
                        duration: candidate.clip.duration,
                        timelineStart: timelineStart)
                    let trackIndex = Self.firstAvailableReplayTrackIndex(
                        in: project.videoTracks,
                        timelineStart: timelineStart,
                        duration: candidate.clip.duration)
                    Self.ensureReplayTrack(at: trackIndex, in: &project.videoTracks, kind: .video)
                    project.videoTracks[trackIndex].clips.append(videoClip)
                }
                if candidate.mediaItem.hasAudio {
                    let audioClip = Clip(
                        mediaID: candidate.mediaItem.id,
                        sourceStart: .zero,
                        duration: candidate.clip.duration,
                        timelineStart: timelineStart)
                    let trackIndex = Self.firstAvailableReplayTrackIndex(
                        in: project.audioTracks,
                        timelineStart: timelineStart,
                        duration: candidate.clip.duration)
                    Self.ensureReplayTrack(at: trackIndex, in: &project.audioTracks, kind: .audio)
                    project.audioTracks[trackIndex].clips.append(audioClip)
                }
            }
            scheduleRebuild()
        }

        let savedDuration = prepared.reduce(CMTime.zero) { result, candidate in
            CMTimeMaximum(result, candidate.clip.timelineOffset + candidate.clip.duration)
        }
        if prepared.count == 1 {
            statusMessage = String(format: "Inserted %.1fs replay clip at playhead.", savedDuration.seconds)
        } else {
            statusMessage = String(
                format: "Inserted %d replay clips spanning %.1fs at playhead.",
                prepared.count,
                savedDuration.seconds)
        }
    }

    private func prepareReplayMediaItem(_ savedClip: ReplayBufferSavedClip,
                                        timestamp: String,
                                        sourceIndex: Int,
                                        sourceCount: Int) async -> MediaItem {
        let mediaItem = MediaItem(url: savedClip.url)
        mediaItem.duration = savedClip.duration
        let sourceName = savedClip.sourceFileURL.deletingPathExtension().lastPathComponent
        mediaItem.name = sourceCount == 1
            ? "Replay \(timestamp)"
            : "Replay \(sourceIndex + 1) - \(sourceName)"

        // Populate media flags so CompositionBuilder recognises replay clips for preview and export.
        let asset = mediaItem.asset
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            mediaItem.hasVideo = true
            mediaItem.naturalSize = (try? await videoTrack.load(.naturalSize))?.sanitized ?? .zero
            mediaItem.preferredTransform = (try? await videoTrack.load(.preferredTransform))?.sanitized ?? .identity
        }
        mediaItem.hasAudio = (try? await !asset.loadTracks(withMediaType: .audio).isEmpty) ?? false
        return mediaItem
    }

    private static func firstAvailableReplayTrackIndex(in tracks: [Track],
                                                       timelineStart: CMTime,
                                                       duration: CMTime) -> Int {
        let timelineEnd = timelineStart + duration
        if let index = tracks.firstIndex(where: { track in
            !track.clips.contains { clip in
                clip.timelineStart < timelineEnd && timelineStart < clip.timelineEnd
            }
        }) {
            return index
        }
        return tracks.count
    }

    private static func ensureReplayTrack(at index: Int,
                                          in tracks: inout [Track],
                                          kind: TrackKind) {
        while tracks.count <= index {
            let prefix = kind == .video ? "V" : "A"
            tracks.append(Track(name: "\(prefix)\(tracks.count + 1)", kind: kind))
        }
    }
}
