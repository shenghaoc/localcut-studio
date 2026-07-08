import Foundation
import AVFoundation
import os
import LocalCutCore

// MARK: - Beat tools

extension EditorModel {

    var selectedBeatSource: MediaItem? {
        // Prefer the timeline clip (consistent with the main inspector): a clip
        // tap sets selectedClipID without clearing an earlier media-bin
        // selection, so checking media first would target the stale source.
        if let clip = selectedClip, let media = project.media(for: clip.mediaID) {
            return media
        }
        return selectedMedia
    }

    var canAnalyzeBeatsForSelection: Bool {
        selectedBeatSource?.hasAudio == true
    }

    var canCutSelectedClipAtBeats: Bool {
        guard let clipID = selectedClipID,
              let context = trackAndClipIndex(for: clipID),
              let media = project.media(for: context.track.clips[context.index].mediaID)
        else { return false }
        return beatAnalyses[media.id] != nil
    }

    var canAlignSelectedClipToBeat: Bool {
        // Match the command's own target set (it aligns to beats excluding the
        // selected clip), so the control isn't enabled only to report "no beat".
        guard let id = selectedClipID else { return false }
        return hasProjectedBeats(excluding: id)
    }

    /// Existence check for command enablement: returns `true` as soon as any clip
    /// other than `clipID` contributes an in-range projected beat. Unlike
    /// `projectedBeatTimes(excluding:)` it short-circuits and skips the cross-clip
    /// dedup/sort, so it's cheap to call on every inspector render.
    func hasProjectedBeats(excluding clipID: Clip.ID?) -> Bool {
        let offset = CMTime(seconds: beatOffsetSeconds, preferredTimescale: 600)
        for track in project.videoTracks + project.audioTracks {
            for clip in track.clips where clip.id != clipID {
                guard let media = project.media(for: clip.mediaID), media.hasAudio,
                      let analysis = beatAnalyses[media.id] else { continue }
                // Short-circuit: compute beats for this clip and return
                // immediately if any are found, avoiding the full cross-clip
                // dedup/sort that projectedBeatTimes(excluding:) performs.
                let beats = projectedBeatTimes(for: clip, analysis: analysis, offset: offset)
                if !beats.isEmpty { return true }
            }
        }
        return false
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
        let scopeStarted = url.startAccessingSecurityScopedResource()

        beatAnalysisTask = Task.detached { [weak self] in
            defer { if scopeStarted { url.stopAccessingSecurityScopedResource() } }
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
                    // The source may have been removed (e.g. the user opened a
                    // different document) while this detached analysis ran; don't
                    // stamp a stale result into the current project.
                    guard self.project.mediaItems.contains(where: { $0.id == mediaID }) else { return }
                    self.beatAnalyses[mediaID] = analysis
                    self.beatAnalysisKeys[mediaID] = key
                    self.showBeatMarkers = true
                    self.statusMessage = "\(sourceLabel) for \(mediaName): \(analysis.beatTimes.count) beats, \(Int(analysis.tempoBPM.rounded())) BPM."
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    // Mirror the success path: a failure from a task cancelled by a
                    // document switch (or for a source no longer present) must not
                    // overwrite the active project's status with a stale message.
                    guard let self, !Task.isCancelled,
                          self.project.mediaItems.contains(where: { $0.id == mediaID }) else { return }
                    self.statusMessage = "Beat analysis failed for \(mediaName): \(error.localizedDescription)"
                }
            }
        }
    }

    func projectedBeatMarkers(excluding clipID: Clip.ID? = nil) -> [ProjectedBeatMarker] {
        projectedBeatTimes(excluding: clipID).enumerated().map { offset, time in
            // Use a deterministic ID based on the time value so the marker
            // identity is stable across rebuilds when the same beat is projected.
            ProjectedBeatMarker(id: "beat-\(time.value)-\(time.timescale)", time: time)
        }
    }

    func invalidateProjectedBeatTimesCache() {
        projectedBeatTimesRevision &+= 1
    }

    func projectedBeatTimes(excluding clipID: Clip.ID? = nil) -> [CMTime] {
        if clipID == nil,
           projectedBeatTimesRevision == lastProjectedBeatTimesRevision {
            return cachedProjectedBeatTimes
        }

        let offset = CMTime(seconds: beatOffsetSeconds, preferredTimescale: 600)
        var times: [CMTime] = []

        for track in project.videoTracks + project.audioTracks {
            for clip in track.clips where clip.id != clipID {
                guard let media = project.media(for: clip.mediaID),
                      media.hasAudio,
                      let analysis = beatAnalyses[media.id] else { continue }
                times.append(contentsOf: projectedBeatTimes(for: clip, analysis: analysis, offset: offset))
            }
        }

        let result = deduplicatedBeatTimes(times)
        if clipID == nil {
            cachedProjectedBeatTimes = result
            lastProjectedBeatTimesRevision = projectedBeatTimesRevision
        }
        return result
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
            var segmentOutputOffset = CMTime.zero

            for cut in cutTimes {
                let outputOffset = CMTimeMaximum(.zero, CMTimeMinimum(cut - clip.timelineStart, clip.outputDuration))
                let outputDuration = outputOffset - segmentOutputOffset
                // Skip zero-duration pieces (e.g. duplicate beat times).
                guard outputDuration > .zero else {
                    segmentTimelineStart = cut
                    continue
                }
                pieces.append(piece(from: clip,
                                    timelineStart: segmentTimelineStart,
                                    outputOffset: segmentOutputOffset,
                                    outputDuration: outputDuration,
                                    preservesIDAndTransition: pieces.isEmpty))
                segmentOutputOffset = outputOffset
                segmentTimelineStart = cut
            }

            let tailOutputDuration = clip.outputDuration - segmentOutputOffset
            if tailOutputDuration > .zero {
                pieces.append(piece(from: clip,
                                    timelineStart: segmentTimelineStart,
                                    outputOffset: segmentOutputOffset,
                                    outputDuration: tailOutputDuration,
                                    preservesIDAndTransition: pieces.isEmpty))
            }

            guard !pieces.isEmpty else {
                statusMessage = "No valid cut points found."
                return
            }

            context.track.clips.replaceSubrange(context.index...context.index, with: pieces)
            context.track.clips.sort { $0.timelineStart < $1.timelineStart }
            selectedClipID = pieces.first?.id
            selectedTransitionClipID = nil
            selectedOverlayID = nil
            statusMessage = "Cut clip at \(pieces.count - 1) beat\(pieces.count - 1 == 1 ? "" : "s")."
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

        // Reject a target whose slot is occupied rather than letting
        // nonOverlappingStart silently drop the clip at a far gap while still
        // reporting a successful align.
        let desiredStart = max(target, .zero)
        let resolvedStart = nonOverlappingStart(for: clip, on: context.track,
                                                requested: desiredStart, excluding: id)
        let oneFrame = CMTime(value: 1, timescale: CMTimeScale(max(1, project.frameRate)))
        guard abs((resolvedStart - desiredStart).seconds) < oneFrame.seconds else {
            statusMessage = "The nearest beat is blocked by another clip on this track."
            return
        }

        performUndoable("Align to Beat") {
            var moved = context.track.clips.remove(at: context.index)
            if moved.transition != nil {
                moved.transition = nil
                if selectedTransitionClipID == id { selectedTransitionClipID = nil }
            }
            moved.timelineStart = resolvedStart
            context.track.clips.append(moved)
            context.track.clips.sort { $0.timelineStart < $1.timelineStart }
            // Drop transitions on neighbours the move pulled apart (a plain clip
            // move sanitises these too).
            sanitizeTransitions()
            selectedClipID = moved.id
            selectedTransitionClipID = nil
            selectedOverlayID = nil
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
                let scopeStarted = item.url.startAccessingSecurityScopedResource()
                // `defer` balances the scoped access on every exit from this
                // iteration, including the `catch { continue }` path — otherwise
                // an unreadable file or corrupt cache leaks the access.
                defer { if scopeStarted { item.url.stopAccessingSecurityScopedResource() } }
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
                // Only adopt caches for media still present in the current
                // project — the document may have changed while loading ran.
                let present = Set(self.project.mediaItems.map(\.id))
                let analyses = loadedAnalyses.filter { present.contains($0.key) }
                let keys = loadedKeys.filter { present.contains($0.key) }
                self.beatAnalyses.merge(analyses) { _, new in new }
                self.beatAnalysisKeys.merge(keys) { _, new in new }
                if !analyses.isEmpty {
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
                do {
                    try BeatAnalysisCache.write(analysis, key: key, in: directory)
                } catch {
                    // Log but don't throw — beat cache persistence is best-effort.
                    os_log(.error, "BeatAnalysisCache: write failed for %{public}@: %{public}@",
                           key, error.localizedDescription)
                }
            }
        }.value
    }

    /// Synchronous beat cache persistence for the save path. Called from
    /// `DocumentController` during user-initiated save. For projects with many
    /// analyzed sources, this could cause a perceptible UI freeze. A future
    /// improvement would move this to a background task and use the async
    /// `persistBeatCaches` method instead.
    func persistBeatCachesSynchronously(to bundleURL: URL) {
        let directory = bundleBeatCacheDirectoryURL(for: bundleURL)
        for (mediaID, analysis) in beatAnalyses {
            guard let key = beatAnalysisKeys[mediaID] else { continue }
            do {
                try BeatAnalysisCache.write(analysis, key: key, in: directory)
            } catch {
                os_log(.error, "BeatAnalysisCache: write failed for %{public}@: %{public}@",
                       key, error.localizedDescription)
            }
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
            let outputOffset = clip.outputOffset(forSourceOffset: beat - clip.sourceStart)
            let timelineTime = clip.timelineStart + outputOffset + offset
            return timelineTime >= .zero ? timelineTime : nil
        }
    }

    /// Cut points for one clip, derived from *that clip's own* analysis projected
    /// through its source-to-timeline mapping with the current offset. Using the
    /// clip's analysis (rather than the global projected set) keeps cuts musically
    /// correct when an unrelated clip's beats overlap this clip's timeline range,
    /// and sidesteps the projected-beat memo entirely.
    private func beatCutTimes(for clip: Clip) -> [CMTime] {
        guard let media = project.media(for: clip.mediaID),
              let analysis = beatAnalyses[media.id] else { return [] }
        let oneFrame = CMTime(value: 1, timescale: CMTimeScale(max(1, project.frameRate)))
        let offset = CMTime(seconds: beatOffsetSeconds, preferredTimescale: 600)
        let projected = projectedBeatTimes(for: clip, analysis: analysis, offset: offset)
        let inBounds = deduplicatedBeatTimes(projected).filter { cut in
            cut - clip.timelineStart >= oneFrame && clip.timelineEnd - cut >= oneFrame
        }
        // Enforce a one-frame minimum between *consecutive* cuts too, so densely
        // spaced beats (high tempo, double onsets) can't produce sub-frame clips
        // that break rendering or zero-width timeline drawing. The trailing
        // segment is already ≥ one frame from the bounds filter above.
        var cuts: [CMTime] = []
        var previous = clip.timelineStart
        for cut in inBounds where cut - previous >= oneFrame {
            cuts.append(cut)
            previous = cut
        }
        return cuts
    }

    /// Merges beats within ≈1.7 ms of each other. This catches exact or
    /// near-exact duplicates when the same source appears on multiple tracks;
    /// it should not be widened to the point where distinct beats from
    /// different sources at similar tempos collide.
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
                       outputOffset: CMTime,
                       outputDuration: CMTime,
                       preservesIDAndTransition: Bool) -> Clip {
        let sourceOffset = clip.sourceOffset(forOutputOffset: outputOffset)
        let sourceEndOffset = clip.sourceOffset(forOutputOffset: outputOffset + outputDuration)
        let sourceStart = clip.sourceStart + sourceOffset
        let duration = CMTimeMaximum(sourceEndOffset - sourceOffset, .zero)
        let speedCurve = slicedKeyframeTrack(clip.speedCurve, from: sourceOffset, duration: duration)
        let effects = mapSkinSmoothStrength(in: clip.effects) {
            slicedKeyframeTrack($0, from: sourceOffset, duration: duration)
        }

        if preservesIDAndTransition {
            var first = clip
            first.timelineStart = timelineStart
            first.sourceStart = sourceStart
            first.duration = duration
            first.speedCurve = speedCurve
            first.effects = effects
            return first
        }
        return Clip(mediaID: clip.mediaID,
                    sourceStart: sourceStart,
                    duration: duration,
                    timelineStart: timelineStart,
                    opacity: clip.opacity,
                    effects: effects,
                    volumeEnvelope: clip.volumeEnvelope,
                    speedCurve: speedCurve,
                    preservePitch: clip.preservePitch,
                    pitchAlgorithm: clip.pitchAlgorithm)
    }

    private func slicedKeyframeTrack(_ track: Keyframed<Float>, from sourceOffset: CMTime, duration: CMTime)
        -> Keyframed<Float> {
        guard track.isAnimated else { return track }
        let endOffset = sourceOffset + duration
        let startValue = track.bezierValue(at: sourceOffset)
        let endValue = track.bezierValue(at: endOffset)
        var keyframes: [Keyframe<Float>] = []

        if let exactStart = track.keyframes.first(where: { $0.time == sourceOffset }) {
            keyframes.append(Keyframe<Float>(
                id: exactStart.id,
                time: .zero,
                value: startValue,
                incomingHandle: exactStart.incomingHandle,
                outgoingHandle: exactStart.outgoingHandle))
        } else {
            keyframes.append(Keyframe<Float>(time: .zero, value: startValue))
        }

        keyframes.append(contentsOf: track.keyframes.compactMap { keyframe in
            guard keyframe.time > sourceOffset, keyframe.time < endOffset else { return nil }
            return Keyframe<Float>(
                id: keyframe.id,
                time: keyframe.time - sourceOffset,
                value: keyframe.value,
                incomingHandle: keyframe.incomingHandle,
                outgoingHandle: keyframe.outgoingHandle)
        })

        if duration > .zero {
            if let exactEnd = track.keyframes.first(where: { $0.time == endOffset }) {
                keyframes.append(Keyframe<Float>(
                    id: exactEnd.id,
                    time: duration,
                    value: endValue,
                    incomingHandle: exactEnd.incomingHandle,
                    outgoingHandle: exactEnd.outgoingHandle))
            } else if keyframes.last?.time != duration {
                keyframes.append(Keyframe<Float>(time: duration, value: endValue))
            }
        }

        return Keyframed<Float>(keyframes: keyframes, defaultValue: track.defaultValue)
    }

    private func mapSkinSmoothStrength(in effects: [Effect],
                                       _ transform: (Keyframed<Float>) -> Keyframed<Float>) -> [Effect] {
        effects.map { effect in
            guard case .skinSmooth(var smooth) = effect else { return effect }
            smooth.strength = transform(smooth.strength)
            return .skinSmooth(smooth)
        }
    }

    private func nearestBeat(to time: CMTime, targets: [CMTime], window: Double) -> CMTime? {
        targets
            .map { (time: $0, distance: abs(($0 - time).seconds)) }
            .filter { $0.distance <= window }
            .min { $0.distance < $1.distance }?
            .time
    }

    private func nonOverlappingStart(for clip: Clip, on track: Track, requested: CMTime,
                                     excluding clipID: Clip.ID? = nil) -> CMTime {
        let duration = clip.outputDuration
        let others = track.clips
            .filter { $0.id != clipID }
            .sorted { $0.timelineStart < $1.timelineStart }
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
