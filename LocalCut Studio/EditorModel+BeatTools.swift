import Foundation
import AVFoundation
import LocalCutCore

// MARK: - Beat tools

extension EditorModel {

    var selectedBeatSource: MediaItem? {
        if let media = selectedMedia { return media }
        guard let clip = selectedClip else { return nil }
        return project.media(for: clip.mediaID)
    }

    var canAnalyzeBeatsForSelection: Bool {
        selectedBeatSource?.hasAudio == true
    }

    var canCutSelectedClipAtBeats: Bool {
        selectedClipID != nil && !beatAnalyses.isEmpty
    }

    var canAlignSelectedClipToBeat: Bool {
        selectedClipID != nil && !projectedBeatTimes().isEmpty
    }

    func analyzeBeatsForSelection() {
        guard let media = selectedBeatSource else {
            statusMessage = "Select an audio source or a clip with audio to analyse beats."
            return
        }
        guard media.hasAudio else {
            statusMessage = "\(media.name) has no audio track to analyse."
            return
        }

        beatAnalysisTask?.cancel()
        statusMessage = "Analysing beats in \(media.name)…"

        let analyzer = beatAnalyzer
        let mediaID = media.id
        let mediaName = media.name
        let url = media.url
        let cacheDirectory = beatCacheDirectoryURL()

        beatAnalysisTask = Task.detached { [weak self] in
            do {
                let key = try Fingerprint.sha256(of: url)
                let cached = try BeatAnalysisCache.read(key: key, in: cacheDirectory)
                let analysis: BeatAnalysis
                let sourceLabel: String
                if let cached {
                    analysis = cached
                    sourceLabel = "Loaded cached beat analysis"
                } else {
                    analysis = try await analyzer.analyze(url: url)
                    try BeatAnalysisCache.write(analysis, key: key, in: cacheDirectory)
                    sourceLabel = "Analysed beats"
                }

                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.beatAnalyses[mediaID] = analysis
                    self.beatAnalysisKeys[mediaID] = key
                    self.showBeatMarkers = true
                    self.statusMessage = "\(sourceLabel) for \(mediaName): \(analysis.beatTimes.count) beats, \(Int(analysis.tempoBPM.rounded())) BPM."
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.statusMessage = "Beat analysis failed for \(mediaName): \(error.localizedDescription)"
                }
            }
        }
    }

    func projectedBeatMarkers(excluding clipID: Clip.ID? = nil) -> [ProjectedBeatMarker] {
        projectedBeatTimes(excluding: clipID).enumerated().map { offset, time in
            ProjectedBeatMarker(id: "\(offset)-\(time.value)-\(time.timescale)", time: time)
        }
    }

    func projectedBeatTimes(excluding clipID: Clip.ID? = nil) -> [CMTime] {
        let offset = CMTime(seconds: beatOffsetSeconds, preferredTimescale: 600)
        var times: [CMTime] = []

        for track in project.audioTracks {
            for clip in track.clips where clip.id != clipID {
                guard let media = project.media(for: clip.mediaID),
                      media.hasAudio,
                      let analysis = beatAnalyses[media.id] else { continue }
                times.append(contentsOf: projectedBeatTimes(for: clip, analysis: analysis, offset: offset))
            }
        }

        return deduplicatedBeatTimes(times)
    }

    func cutSelectedClipAtBeats() {
        guard let id = selectedClipID else { return }
        guard let context = trackAndClipIndex(for: id) else { return }
        let clip = context.track.clips[context.index]
        let cutTimes = beatCutTimes(for: clip)

        guard !cutTimes.isEmpty else {
            statusMessage = "No analysed beats fall inside the selected clip."
            return
        }

        performUndoable("Cut at Beats") {
            var pieces: [Clip] = []
            var segmentTimelineStart = clip.timelineStart
            var segmentSourceStart = clip.sourceStart

            for cut in cutTimes {
                let duration = cut - segmentTimelineStart
                pieces.append(piece(from: clip,
                                    timelineStart: segmentTimelineStart,
                                    sourceStart: segmentSourceStart,
                                    duration: duration,
                                    preservesIDAndTransition: pieces.isEmpty))
                segmentSourceStart = segmentSourceStart + duration
                segmentTimelineStart = cut
            }

            let tailDuration = clip.timelineEnd - segmentTimelineStart
            pieces.append(piece(from: clip,
                                timelineStart: segmentTimelineStart,
                                sourceStart: segmentSourceStart,
                                duration: tailDuration,
                                preservesIDAndTransition: pieces.isEmpty))

            context.track.clips.replaceSubrange(context.index...context.index, with: pieces)
            context.track.clips.sort { $0.timelineStart < $1.timelineStart }
            selectedClipID = pieces.first?.id
            selectedTransitionClipID = nil
            statusMessage = "Cut clip at \(cutTimes.count) beat\(cutTimes.count == 1 ? "" : "s")."
            scheduleRebuild()
        }
    }

    func alignSelectedClipToBeat() {
        guard let id = selectedClipID else { return }
        guard let context = trackAndClipIndex(for: id) else { return }
        let clip = context.track.clips[context.index]
        let targets = projectedBeatTimes(excluding: id)
        guard let target = nearestBeat(to: clip.timelineStart, targets: targets, window: beatAlignWindowSeconds) else {
            statusMessage = "No beat is within \(Int(beatAlignWindowSeconds * 1000)) ms of the selected clip."
            return
        }

        performUndoable("Align to Beat") {
            var moved = context.track.clips.remove(at: context.index)
            if moved.transition != nil {
                moved.transition = nil
                if selectedTransitionClipID == id { selectedTransitionClipID = nil }
            }
            moved.timelineStart = max(target, .zero)
            moved.timelineStart = nonOverlappingStart(for: moved, on: context.track, requested: moved.timelineStart)
            context.track.clips.append(moved)
            context.track.clips.sort { $0.timelineStart < $1.timelineStart }
            selectedClipID = moved.id
            selectedTransitionClipID = nil
            statusMessage = "Aligned clip to beat at \(TimeFormatting.timecode(moved.timelineStart.seconds))."
            scheduleRebuild()
        }
    }

    func loadAvailableBeatCaches() {
        let media = project.mediaItems
            .filter(\.hasAudio)
            .map { (id: $0.id, url: $0.url) }
        guard !media.isEmpty else { return }

        let cacheDirectory = beatCacheDirectoryURL()
        beatAnalysisTask?.cancel()
        beatAnalysisTask = Task.detached { [weak self] in
            var loadedAnalyses: [MediaItem.ID: BeatAnalysis] = [:]
            var loadedKeys: [MediaItem.ID: String] = [:]

            for item in media {
                guard !Task.isCancelled else { return }
                do {
                    let key = try Fingerprint.sha256(of: item.url)
                    if let analysis = try BeatAnalysisCache.read(key: key, in: cacheDirectory) {
                        loadedAnalyses[item.id] = analysis
                        loadedKeys[item.id] = key
                    }
                } catch {
                    continue
                }
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.beatAnalyses.merge(loadedAnalyses) { _, new in new }
                self.beatAnalysisKeys.merge(loadedKeys) { _, new in new }
                if !loadedAnalyses.isEmpty {
                    self.showBeatMarkers = true
                }
            }
        }
    }

    func persistBeatCaches(to bundleURL: URL) async {
        let entries = beatAnalyses.compactMap { mediaID, analysis -> (String, BeatAnalysis)? in
            guard let key = beatAnalysisKeys[mediaID] else { return nil }
            return (key, analysis)
        }
        guard !entries.isEmpty else { return }
        let directory = bundleBeatCacheDirectoryURL(for: bundleURL)
        await Task.detached {
            for (key, analysis) in entries {
                try? BeatAnalysisCache.write(analysis, key: key, in: directory)
            }
        }.value
    }

    func persistBeatCachesSynchronously(to bundleURL: URL) {
        let directory = bundleBeatCacheDirectoryURL(for: bundleURL)
        for (mediaID, analysis) in beatAnalyses {
            guard let key = beatAnalysisKeys[mediaID] else { continue }
            try? BeatAnalysisCache.write(analysis, key: key, in: directory)
        }
    }

    func beatCacheDirectoryURL() -> URL {
        if let documentURL, ProjectBundle.isBundle(url: documentURL) {
            return bundleBeatCacheDirectoryURL(for: documentURL)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.shenghaoc.LocalCutStudio"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("BeatAnalysis", isDirectory: true)
    }

    func bundleBeatCacheDirectoryURL(for bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(ProjectBundleLayout.beatCachesSubdirectory, isDirectory: true)
    }

    private func projectedBeatTimes(for clip: Clip,
                                    analysis: BeatAnalysis,
                                    offset: CMTime) -> [CMTime] {
        let sourceEnd = clip.sourceStart + clip.duration
        return analysis.beatTimes.compactMap { beat in
            guard beat >= clip.sourceStart, beat <= sourceEnd else { return nil }
            let timelineTime = clip.timelineStart + (beat - clip.sourceStart) + offset
            return timelineTime >= .zero ? timelineTime : nil
        }
    }

    private func beatCutTimes(for clip: Clip) -> [CMTime] {
        let oneFrame = CMTime(value: 1, timescale: CMTimeScale(max(1, project.frameRate)))
        let timelineRange = CMTimeRange(start: clip.timelineStart, end: clip.timelineEnd)
        var cuts = projectedBeatTimes().filter { timelineRange.containsTime($0) }

        if cuts.isEmpty,
           let media = project.media(for: clip.mediaID),
           let analysis = beatAnalyses[media.id] {
            cuts = projectedBeatTimes(for: clip,
                                      analysis: analysis,
                                      offset: CMTime(seconds: beatOffsetSeconds, preferredTimescale: 600))
        }

        return deduplicatedBeatTimes(cuts).filter { cut in
            cut - clip.timelineStart >= oneFrame && clip.timelineEnd - cut >= oneFrame
        }
    }

    private func deduplicatedBeatTimes(_ times: [CMTime]) -> [CMTime] {
        let sorted = times.sorted()
        var result: [CMTime] = []
        let tolerance = CMTime(value: 1, timescale: 600)
        for time in sorted {
            guard let last = result.last else {
                result.append(time)
                continue
            }
            if abs((time - last).seconds) > tolerance.seconds {
                result.append(time)
            }
        }
        return result
    }

    private func trackAndClipIndex(for clipID: Clip.ID) -> (track: Track, index: Int)? {
        for track in project.videoTracks + project.audioTracks {
            if let index = track.clips.firstIndex(where: { $0.id == clipID }) {
                return (track, index)
            }
        }
        return nil
    }

    private func piece(from clip: Clip,
                       timelineStart: CMTime,
                       sourceStart: CMTime,
                       duration: CMTime,
                       preservesIDAndTransition: Bool) -> Clip {
        if preservesIDAndTransition {
            var first = clip
            first.timelineStart = timelineStart
            first.sourceStart = sourceStart
            first.duration = duration
            return first
        }
        return Clip(mediaID: clip.mediaID,
                    sourceStart: sourceStart,
                    duration: duration,
                    timelineStart: timelineStart,
                    opacity: clip.opacity,
                    effects: clip.effects,
                    volumeEnvelope: clip.volumeEnvelope)
    }

    private func nearestBeat(to time: CMTime, targets: [CMTime], window: Double) -> CMTime? {
        targets
            .map { (time: $0, distance: abs(($0 - time).seconds)) }
            .filter { $0.distance <= window }
            .min { $0.distance < $1.distance }?
            .time
    }

    private func nonOverlappingStart(for clip: Clip, on track: Track, requested: CMTime) -> CMTime {
        let duration = clip.duration
        let others = track.clips.sorted { $0.timelineStart < $1.timelineStart }
        let requestedEnd = requested + duration
        let hasOverlap = others.contains { other in
            requested < other.timelineEnd && requestedEnd > other.timelineStart
        }
        if !hasOverlap { return requested }

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
}
