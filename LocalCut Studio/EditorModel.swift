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

    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingRebuildTask: Task<Void, Never>?

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
        pendingRebuildTask?.cancel()
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
                         opacity: clip.opacity,
                         effects: clip.effects)

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

    /// Mutates the selected clip and schedules a debounced rebuild (for continuous
    /// drags such as colour sliders). Cancels any pending rebuild.
    func updateSelectedClipCoalesced(_ transform: (inout Clip) -> Void) {
        guard let id = selectedClipID else { return }
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            transform(&track.clips[index])
            rebuildDebounced()
            return
        }
    }

    private func rebuildDebounced(after delay: Duration = .milliseconds(200)) {
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await rebuild()
        }
    }

    // MARK: - Colour grading

    /// Returns the colour grade for the selected clip, inserting a neutral one if absent.
    var selectedClipGrade: ColourGrade {
        get {
            guard let clip = selectedClip else { return .neutral }
            if let effect = clip.effects.first(where: { if case .colourGrade = $0 { return true }; return false }),
               case .colourGrade(let g) = effect {
                return g
            }
            return .neutral
        }
        set {
            guard let id = selectedClipID else { return }
            for track in allTracks {
                guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
                var grade = newValue
                grade.clamp()
                if let effectIndex = track.clips[index].effects.firstIndex(where: {
                    if case .colourGrade = $0 { return true }; return false
                }) {
                    track.clips[index].effects[effectIndex] = .colourGrade(grade)
                } else {
                    track.clips[index].effects.append(.colourGrade(grade))
                }
                rebuildDebounced()
                return
            }
        }
    }

    /// Removes all colour effects from the selected clip.
    func resetClipColourEffects() {
        guard let id = selectedClipID else { return }
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            track.clips[index].effects.removeAll()
            Task { await rebuild() }
            return
        }
    }

    /// Imports a .cube LUT file and attaches it as a LUT effect on the selected clip.
    func importLUT(url: URL) {
        guard let id = selectedClipID,
              let selectedTrack = track(for: id),
              selectedTrack.kind == .video else {
            statusMessage = "Select a video clip before importing a LUT."
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            statusMessage = "Could not access \(url.lastPathComponent)."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            statusMessage = "Could not store access to \(url.lastPathComponent)."
            return
        }

        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            track.clips[index].effects.append(.lut(bookmark: bookmark))
            statusMessage = "Imported LUT \(url.lastPathComponent)."
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

    /// Finds the `Track` that contains the clip with the given ID.
    func track(for clipID: Clip.ID) -> Track? {
        allTracks.first { $0.clips.contains(where: { $0.id == clipID }) }
    }

    /// Applies a closure to the clip with the given ID, then rebuilds.
    private func applyToClip(id: Clip.ID, _ transform: (inout Clip) -> Void) {
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            transform(&track.clips[index])
            Task { await rebuild() }
            return
        }
    }

    /// Which edge of a clip is being trimmed.
    enum TrimEdge {
        case left, right
    }

    /// Minimum clip duration (one frame at 30 fps).
    private static let minClipDuration = CMTime(value: 1, timescale: 30)

    /// Trims the clip with the given ID. For the left edge, `to` is the new
    /// `timelineStart`; for the right edge, `to` is the new `timelineEnd`.
    /// Values are clamped to source bounds and minimum duration.
    func trimClip(id: Clip.ID, edge: TrimEdge, to: CMTime) {
        guard let clip = track(for: id)?.clips.first(where: { $0.id == id }),
              let media = project.media(for: clip.mediaID) else { return }
        let sourceDuration = media.duration

        switch edge {
        case .left:
            let minTimelineStart = max(.zero, clip.timelineStart - clip.sourceStart)
            let maxTimelineStart = clip.timelineEnd - Self.minClipDuration
            let clampedSeconds = max(minTimelineStart.seconds, min(maxTimelineStart.seconds, to.seconds))
            let newTimelineStart = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
            let delta = newTimelineStart - clip.timelineStart
            let newSourceStart = clip.sourceStart + delta
            let finalDuration = clip.duration - delta

            applyToClip(id: id) { clip in
                clip.sourceStart = newSourceStart
                clip.timelineStart = newTimelineStart
                clip.duration = finalDuration
            }

        case .right:
            let minTimelineEnd = clip.timelineStart + Self.minClipDuration
            let sourceMax = clip.timelineStart + (sourceDuration - clip.sourceStart)
            let nextClipStart = track(for: id)?.clips
                .filter { $0.timelineStart > clip.timelineStart }
                .min { $0.timelineStart < $1.timelineStart }?
                .timelineStart
            let maxTimelineEnd = min(sourceMax, nextClipStart ?? sourceMax)
            let clampedSeconds = max(minTimelineEnd.seconds, min(maxTimelineEnd.seconds, to.seconds))
            let newTimelineEnd = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
            let finalDuration = newTimelineEnd - clip.timelineStart

            applyToClip(id: id) { clip in
                clip.duration = finalDuration
            }
        }
    }

    /// Moves the clip to a new track (by index among tracks of the same kind) and
    /// start time, resolving overlaps. Pass `trackIndex` as the 0-based index
    /// within tracks of the same kind as the clip's current track.
    func moveClip(id: Clip.ID, toTrackIndex: Int, start: CMTime) {
        guard let source = track(for: id)?.clips.first(where: { $0.id == id }),
              let sourceTrack = track(for: id) else { return }

        let sameKindTracks: [Track] = sourceTrack.kind == .video ? project.videoTracks : project.audioTracks
        let targetTrack: Track
        if toTrackIndex >= 0, toTrackIndex < sameKindTracks.count {
            targetTrack = sameKindTracks[toTrackIndex]
        } else {
            targetTrack = sourceTrack
        }

        for t in allTracks {
            t.clips.removeAll { $0.id == id }
        }

        let resolved = targetTrack.nearestNonOverlappingStart(for: source.duration, desired: CMTimeMaximum(.zero, start))
        var moved = source
        moved.timelineStart = resolved
        targetTrack.clips.append(moved)
        targetTrack.clips.sort { $0.timelineStart < $1.timelineStart }
        selectedClipID = moved.id

        Task { await rebuild() }
    }

    /// All snap points — every clip boundary, zero, and the playhead.
    func snapTargets(excluding clipID: Clip.ID? = nil) -> Set<CMTime> {
        var targets: Set<CMTime> = [.zero]
        for track in allTracks {
            for clip in track.clips where clip.id != clipID {
                targets.insert(clip.timelineStart)
                targets.insert(clip.timelineEnd)
            }
        }
        if currentTime > 0 {
            targets.insert(CMTime(seconds: currentTime, preferredTimescale: 600))
        }
        return targets
    }

    /// Returns the nearest snap target within `thresholdSeconds`, or the candidate
    /// if none is close enough.
    func resolveSnap(candidate: CMTime, thresholdSeconds: Double, excluding clipID: Clip.ID? = nil) -> CMTime {
        let targets = snapTargets(excluding: clipID)
        let nearest = targets.min { abs($0.seconds - candidate.seconds) < abs($1.seconds - candidate.seconds) }
        if let nearest, abs(nearest.seconds - candidate.seconds) <= thresholdSeconds {
            return nearest
        }
        return candidate
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
