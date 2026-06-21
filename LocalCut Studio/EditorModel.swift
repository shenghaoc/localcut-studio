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
        sanitizeTransitions()
        statusMessage = "Deleted clip."
        Task { await rebuild() }
    }

    /// Clears any clip-owned transition whose cut no longer exists — i.e. the
    /// clip is no longer immediately adjacent to a preceding clip. Prevents a
    /// stored transition from silently re-binding to a different neighbour after
    /// a move/trim/delete changes adjacency.
    private func sanitizeTransitions() {
        for track in allTracks {
            let ordered = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            for (position, clip) in ordered.enumerated() where clip.transition != nil {
                let adjacent = position > 0 &&
                    abs((clip.timelineStart - ordered[position - 1].timelineEnd).seconds) < TransitionLayout.adjacencyTolerance
                if !adjacent, let index = track.clips.firstIndex(where: { $0.id == clip.id }) {
                    track.clips[index].transition = nil
                    if selectedTransitionClipID == clip.id { selectedTransitionClipID = nil }
                }
            }
        }
    }

    /// Splits the selected clip at the current playhead into two adjacent clips.
    func splitSelectedClipAtPlayhead() {
        guard let id = selectedClipID else { return }

        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = track.clips[index]

            // The playhead is in effective (rippled) time; convert to this clip's
            // authored time using its constant ripple shift so the split lands at
            // the frame the user sees.
            let cuts = TransitionLayout.cuts(videoTracks: project.videoTracks)
            let placements = TransitionLayout.placements(for: track.clips, cuts: cuts)
            let shift = placements.first(where: { $0.id == id })
                .map { clip.timelineStart - $0.effectiveStart } ?? .zero
            let playhead = CMTime(seconds: currentTime, preferredTimescale: 600) + shift

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

    func clip(for clipID: Clip.ID) -> Clip? {
        for track in allTracks {
            if let clip = track.clips.first(where: { $0.id == clipID }) { return clip }
        }
        return nil
    }

    // MARK: - Transitions

    /// The trailing clip whose transition is currently selected, if any.
    var selectedTransitionClipID: Clip.ID?

    /// The selected transition, or `nil` if none is selected (or it was removed).
    var selectedTransition: Transition? {
        guard let id = selectedTransitionClipID else { return nil }
        return clip(for: id)?.transition
    }

    /// The adjacent predecessor of `clipID` on the same track, if the two clips
    /// are butt-joined (a valid cut to host a transition).
    private func adjacentPredecessor(of clipID: Clip.ID) -> (track: Track, previous: Clip, clip: Clip)? {
        guard let track = track(for: clipID) else { return nil }
        let ordered = track.clips.sorted { $0.timelineStart < $1.timelineStart }
        guard let index = ordered.firstIndex(where: { $0.id == clipID }), index > 0 else { return nil }
        let previous = ordered[index - 1]
        let clip = ordered[index]
        let gap = abs((clip.timelineStart - previous.timelineEnd).seconds)
        guard gap < TransitionLayout.adjacencyTolerance else { return nil }
        return (track, previous, clip)
    }

    /// The overlap available to `clipID`'s incoming transition, matching the
    /// render-time clamp: the predecessor's head is already consumed by *its* own
    /// transition, so only its remaining tail (and this clip's length) is free.
    private func chainedAvailableOverlap(forClip clipID: Clip.ID) -> CMTime {
        guard let context = adjacentPredecessor(of: clipID) else { return .zero }
        let ordered = context.track.clips.sorted { $0.timelineStart < $1.timelineStart }
        let overlaps = TransitionLayout.orderedOverlaps(ordered)
        guard let index = ordered.firstIndex(where: { $0.id == clipID }) else { return .zero }
        let availableTail = CMTimeMaximum(context.previous.duration - overlaps[index - 1], .zero)
        return CMTimeMinimum(context.clip.duration, availableTail)
    }

    /// Whether a transition can be added at the current clip selection: a video
    /// clip that follows an adjacent clip and does not already have one.
    var canAddTransitionAtSelection: Bool {
        guard let id = selectedClipID,
              let context = adjacentPredecessor(of: id),
              context.track.kind == .video,
              context.clip.transition == nil else { return false }
        return true
    }

    /// The largest overlap available to the selected transition, accounting for
    /// chained transitions. Drives the inspector's duration ceiling so it matches
    /// what the render will actually allow.
    var selectedTransitionMaxDuration: CMTime {
        guard let id = selectedTransitionClipID else { return .zero }
        return chainedAvailableOverlap(forClip: id)
    }

    /// Adds a default cross-dissolve at the selected clip's incoming cut,
    /// clamped to the available overlap, and selects it for editing.
    func addTransitionToSelectedClip() {
        guard let id = selectedClipID,
              let context = adjacentPredecessor(of: id),
              context.track.kind == .video else {
            statusMessage = "Select a video clip that follows another to add a transition."
            return
        }
        let duration = CMTimeMinimum(Transition.defaultDuration, chainedAvailableOverlap(forClip: id))
        setTransition(Transition(duration: duration), onClip: id)
        selectedClipID = nil
        selectedMediaID = nil
        selectedTransitionClipID = id
        statusMessage = "Added transition."
    }

    /// Mutates the selected transition. Continuous edits (duration drag) pass
    /// `coalesced: true` to debounce the rebuild.
    func updateSelectedTransition(coalesced: Bool = false, _ body: (inout Transition) -> Void) {
        guard let id = selectedTransitionClipID else { return }
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }),
                  var transition = track.clips[index].transition else { continue }
            body(&transition)
            track.clips[index].transition = transition
            if coalesced { rebuildDebounced() } else { Task { await rebuild() } }
            return
        }
    }

    /// Removes the selected transition, restoring the plain cut (R3.3).
    func removeSelectedTransition() {
        guard let id = selectedTransitionClipID else { return }
        setTransition(nil, onClip: id)
        selectedTransitionClipID = nil
        statusMessage = "Removed transition."
    }

    private func setTransition(_ transition: Transition?, onClip id: Clip.ID) {
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            track.clips[index].transition = transition
            Task { await rebuild() }
            return
        }
    }

    // MARK: - Trim & drag

    enum TrimEdge { case left, right }

    /// One render frame at the project's frame rate — the shortest a clip can be.
    private var minClipDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, project.frameRate)))
    }

    /// Trims a clip edge to the given timeline time, clamping to source bounds,
    /// a one-frame minimum length, and neighbouring clip boundaries on the same
    /// track so trims never create overlaps.
    func trimClip(id: Clip.ID, edge: TrimEdge, to time: CMTime) {
        for track in allTracks {
            guard let index = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            var clip = track.clips[index]
            guard let media = project.media(for: clip.mediaID) else { return }
            let sourceDuration = media.duration
            let minDur = minClipDuration

            let sorted = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            let sortedIndex = sorted.firstIndex(where: { $0.id == id })!
            let prevClip = sortedIndex > 0 ? sorted[sortedIndex - 1] : nil
            let nextClip = sortedIndex < sorted.count - 1 ? sorted[sortedIndex + 1] : nil

            switch edge {
            case .left:
                let originalEnd = clip.timelineEnd
                var newTimelineStart = max(time, .zero)
                let minTimelineStart = clip.timelineStart - clip.sourceStart
                newTimelineStart = max(newTimelineStart, minTimelineStart)
                let maxTimelineStart = originalEnd - minDur
                newTimelineStart = min(newTimelineStart, maxTimelineStart)
                if let prev = prevClip {
                    newTimelineStart = max(newTimelineStart, prev.timelineEnd)
                }

                let delta = newTimelineStart - clip.timelineStart
                clip.sourceStart = clip.sourceStart + delta
                clip.timelineStart = newTimelineStart
                clip.duration = originalEnd - newTimelineStart

            case .right:
                let maxSourceRemaining = sourceDuration - clip.sourceStart
                var newDuration = time - clip.timelineStart
                newDuration = max(newDuration, minDur)
                newDuration = min(newDuration, maxSourceRemaining)
                if let next = nextClip {
                    let maxDuration = next.timelineStart - clip.timelineStart
                    newDuration = min(newDuration, maxDuration)
                }
                clip.duration = newDuration
            }

            track.clips[index] = clip
            sanitizeTransitions()
            Task { await rebuild() }
            return
        }
    }

    /// Moves a clip to a target track at the given timeline start. The target
    /// track must be the same kind (video↔video, audio↔audio). Overlapping clips
    /// on the target track are resolved by snapping to the nearest gap.
    func moveClip(id: Clip.ID, toTrack targetTrackID: Track.ID, start: CMTime) {
        var sourceTrack: Track?
        var sourceIndex: Int?
        for track in allTracks {
            if let idx = track.clips.firstIndex(where: { $0.id == id }) {
                sourceTrack = track
                sourceIndex = idx
                break
            }
        }
        guard let sourceTrack, let sourceIndex else { return }
        guard let targetTrack = allTracks.first(where: { $0.id == targetTrackID }) else { return }
        guard sourceTrack.kind == targetTrack.kind else { return }

        var clip = sourceTrack.clips[sourceIndex]
        // Moving a clip destroys its incoming-transition cut; drop it so the
        // transition can't silently re-bind to a new neighbour at the drop site.
        if clip.transition != nil {
            clip.transition = nil
            if selectedTransitionClipID == id { selectedTransitionClipID = nil }
        }
        let newStart = max(start, .zero)
        clip.timelineStart = newStart

        // Remove from source before resolving overlaps on target.
        sourceTrack.clips.remove(at: sourceIndex)

        // Resolve overlaps: find a non-overlapping position on the target track.
        clip.timelineStart = resolveOverlap(clip: clip, on: targetTrack)
        targetTrack.clips.append(clip)
        targetTrack.clips.sort { $0.timelineStart < $1.timelineStart }

        sanitizeTransitions()
        Task { await rebuild() }
    }

    /// Finds the nearest non-overlapping position for a clip on a track.
    /// Prefers the requested position; shifts to the nearest gap if blocked.
    private func resolveOverlap(clip: Clip, on track: Track) -> CMTime {
        let requested = clip.timelineStart
        let duration = clip.duration
        let others = track.clips.sorted { $0.timelineStart < $1.timelineStart }

        let requestedEnd = requested + duration
        let hasOverlap = others.contains { other in
            requested < other.timelineEnd && requestedEnd > other.timelineStart
        }
        if !hasOverlap { return requested }

        // Candidate positions: timeline origin, just after each clip, and
        // just before each clip (shifted back by duration) to cover gaps
        // that end at a clip's start.
        var candidates: [CMTime] = [.zero]
        for other in others {
            candidates.append(other.timelineEnd)
            let beforeClip = other.timelineStart - duration
            if beforeClip >= .zero {
                candidates.append(beforeClip)
            }
        }

        var bestStart = requested
        var bestDistance = Double.infinity
        for candidate in candidates {
            let candidateEnd = candidate + duration
            let wouldOverlap = others.contains { other in
                candidate < other.timelineEnd && candidateEnd > other.timelineStart
            }
            if !wouldOverlap {
                let distance = abs((candidate - requested).seconds)
                if distance < bestDistance {
                    bestDistance = distance
                    bestStart = candidate
                }
            }
        }
        return bestStart
    }

    /// Collects all snap targets: playhead position, every clip boundary
    /// (excluding the given clip), and the timeline origin (0).
    func snapTargets(excluding clipID: Clip.ID? = nil) -> [CMTime] {
        var targets: [CMTime] = [
            .zero,
            CMTime(seconds: currentTime, preferredTimescale: 600)
        ]
        for track in allTracks {
            for clip in track.clips where clip.id != clipID {
                targets.append(clip.timelineStart)
                targets.append(clip.timelineEnd)
            }
        }
        return targets
    }

    /// Returns the nearest snap target within threshold, or the candidate
    /// itself if nothing is close enough. When `trailingEdgeOffset` is
    /// provided, the trailing edge is also tested and the start is adjusted
    /// so the trailing edge lands on the target.
    func resolveSnap(candidate: CMTime, excluding clipID: Clip.ID? = nil,
                     trailingEdgeOffset: CMTime? = nil, threshold: Double? = nil) -> CMTime {
        let thresholdSeconds = threshold ?? (8.0 / pixelsPerSecond)
        let targets = snapTargets(excluding: clipID)

        var nearest = candidate
        var minDist = Double.infinity

        for target in targets {
            let dist = abs((candidate - target).seconds)
            if dist < thresholdSeconds, dist < minDist {
                minDist = dist
                nearest = target
            }
        }

        if let offset = trailingEdgeOffset {
            let trailing = candidate + offset
            for target in targets {
                let dist = abs((trailing - target).seconds)
                if dist < thresholdSeconds, dist < minDist {
                    minDist = dist
                    nearest = target - offset
                }
            }
        }

        return nearest
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
            item.audioMix = built.audioMix
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
            session.audioMix = built.audioMix

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
