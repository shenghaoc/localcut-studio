import Foundation
import AVFoundation
import CoreGraphics
import Observation

/// The single source of truth driving the editor UI: it owns the project, the
/// preview `AVPlayer`, the current selection, and the timeline view state, and it
/// rebuilds the composition whenever the arrangement changes.
@Observable
@MainActor
final class EditorModel {

    let project = Project()

    // Selection
    var selectedClipID: Clip.ID?
    var selectedMediaID: MediaItem.ID?

    // Playback
    let player = AVPlayer()
    var isPlaying = false
    /// Playhead position in seconds.
    var currentTime: Double = 0
    var totalDuration: Double = 0

    // Timeline view state
    var pixelsPerSecond: Double = 80

    // Status / export
    var statusMessage = "Import media to begin."
    var exportProgress: Double?
    var isExporting = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - Import

    /// Loads the given files into the media bin, reading metadata and a poster
    /// frame for each. Security-scoped access is retained for the session.
    func importMedia(urls: [URL]) async {
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            let item = MediaItem(url: url)
            do {
                let duration = try await item.asset.load(.duration)
                item.duration = duration

                let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
                if let v = videoTracks.first {
                    item.hasVideo = true
                    item.naturalSize = try await v.load(.naturalSize)
                    item.preferredTransform = try await v.load(.preferredTransform)
                }
                item.hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty

                project.mediaItems.append(item)
                statusMessage = "Imported \(item.name)."
                Task { await self.generateThumbnail(for: item) }
            } catch {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                statusMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func generateThumbnail(for item: MediaItem) async {
        guard item.hasVideo else { return }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let time = CMTime(seconds: min(0.1, item.durationSeconds / 2), preferredTimescale: 600)
        if let result = try? await generator.image(at: time) {
            item.thumbnail = result.image
        }
    }

    // MARK: - Timeline editing

    /// Appends a media item to the end of the timeline (ripple-append) on the
    /// first video and/or audio track, depending on what the media contains.
    func addToTimeline(mediaID: MediaItem.ID) {
        guard let media = project.media(for: mediaID) else { return }
        let insertAt = project.duration
        let fullRange = CMTimeRange(start: .zero, duration: media.duration)

        if media.hasVideo, let track = project.videoTracks.first {
            track.clips.append(Clip(mediaID: mediaID,
                                    sourceStart: fullRange.start,
                                    duration: fullRange.duration,
                                    timelineStart: insertAt))
        }
        if media.hasAudio, let track = project.audioTracks.first {
            track.clips.append(Clip(mediaID: mediaID,
                                    sourceStart: fullRange.start,
                                    duration: fullRange.duration,
                                    timelineStart: insertAt))
        }
        statusMessage = "Added \(media.name) to timeline."
        Task { await rebuild() }
    }

    /// All tracks, flattened, for lookups.
    private var allTracks: [Track] { project.videoTracks + project.audioTracks }

    func deleteSelectedClip() {
        guard let id = selectedClipID else { return }
        for track in allTracks {
            track.clips.removeAll { $0.id == id }
        }
        selectedClipID = nil
        statusMessage = "Deleted clip."
        Task { await rebuild() }
    }

    /// Splits the selected clip at the current playhead into two adjacent clips.
    func splitSelectedClipAtPlayhead() {
        guard let id = selectedClipID else { return }
        let playhead = CMTime(seconds: currentTime, preferredTimescale: 600)

        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = track.clips[index]
            guard playhead > clip.timelineStart, playhead < clip.timelineEnd else { return }

            let offset = playhead - clip.timelineStart
            var left = clip
            left.duration = offset

            var right = clip
            right = Clip(mediaID: clip.mediaID,
                         sourceStart: clip.sourceStart + offset,
                         duration: clip.duration - offset,
                         timelineStart: playhead,
                         opacity: clip.opacity)

            track.clips.replaceSubrange(index...index, with: [left, right])
            selectedClipID = left.id
            statusMessage = "Split clip."
            Task { await rebuild() }
            return
        }
    }

    /// Mutates the selected clip in place via the supplied closure, then rebuilds.
    func updateSelectedClip(_ transform: (inout Clip) -> Void) {
        guard let id = selectedClipID else { return }
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            transform(&track.clips[index])
            Task { await rebuild() }
            return
        }
    }

    var selectedClip: Clip? {
        guard let id = selectedClipID else { return nil }
        for track in allTracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    var selectedMedia: MediaItem? {
        guard let id = selectedMediaID else { return nil }
        return project.media(for: id)
    }

    // MARK: - Composition / playback

    /// Rebuilds the preview composition from the current project state, keeping
    /// the playhead where it was.
    func rebuild() async {
        let resumeAt = currentTime
        do {
            guard let built = try await CompositionBuilder.build(project: project) else {
                player.replaceCurrentItem(with: nil)
                totalDuration = 0
                return
            }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            player.replaceCurrentItem(with: item)
            totalDuration = built.duration
            await player.seek(to: CMTime(seconds: min(resumeAt, built.duration), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        } catch {
            statusMessage = "Preview build failed: \(error.localizedDescription)"
        }
    }

    func togglePlayPause() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= totalDuration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(toSeconds seconds: Double) {
        let clamped = max(0, min(seconds, totalDuration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Export

    func export(to url: URL) async {
        guard !isExporting else { return }
        do {
            guard let built = try await CompositionBuilder.build(project: project) else {
                statusMessage = "Nothing to export."
                return
            }
            guard let session = AVAssetExportSession(asset: built.composition,
                                                     presetName: AVAssetExportPresetHighestQuality) else {
                statusMessage = "Could not create export session."
                return
            }
            session.videoComposition = built.videoComposition

            try? FileManager.default.removeItem(at: url)

            isExporting = true
            exportProgress = 0
            statusMessage = "Exporting…"

            let progressTask = Task { [weak self] in
                for await state in session.states(updateInterval: 0.25) {
                    if case .exporting(let progress) = state {
                        await MainActor.run { self?.exportProgress = progress.fractionCompleted }
                    }
                }
            }

            defer {
                progressTask.cancel()
                isExporting = false
                exportProgress = nil
            }

            try await session.export(to: url, as: .mov)
            statusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
            isExporting = false
            exportProgress = nil
        }
    }
}
