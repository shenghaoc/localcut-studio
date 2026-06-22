import Foundation
import AVFoundation
import CoreGraphics

/// The product of building a project: an immutable composition plus the video
/// composition that describes how its video layers are transformed and stacked.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
    let duration: Double
}

/// Translates a `Project` into AVFoundation objects suitable for both preview
/// (`AVPlayerItem`) and export (`AVAssetExportSession`).
///
/// This is the native counterpart to the browser project's compositing engine:
/// instead of a WebGPU pipeline we lean on AVFoundation composition tracks plus
/// a custom video compositor to transform, grade, and stack each track.
enum CompositionBuilder {

    enum BuildError: Error { case noVideoTrackInSource, noAudioTrackInSource }

    /// One placed clip on a composition track, in *effective* (rippled) timeline
    /// coordinates, with the transform/opacity/effects to apply while on screen.
    /// `transitionRange`/`transitionType` are set on the incoming clip of a
    /// transition so the compositor can blend it with its predecessor.
    private struct VideoSegment {
        let clipID: UUID
        let compTrackID: CMPersistentTrackID
        let timeRange: CMTimeRange
        let transform: CGAffineTransform
        let opacity: Float
        let effects: [Effect]
        let transitionRange: CMTimeRange?
        let transitionType: TransitionType?
        let showSkinMask: Bool
        let clipStartTime: CMTime
        let sourceRange: CMTimeRange

        var layer: CompositorLayer {
            CompositorLayer(clipID: clipID, trackID: compTrackID, transform: transform, opacity: opacity, effects: effects, showSkinMask: showSkinMask, clipStartTime: clipStartTime, sourceRange: sourceRange, timeRange: timeRange)
        }

        func contains(_ seconds: Double) -> Bool {
            timeRange.start.seconds <= seconds && seconds < timeRange.end.seconds
        }

        var descriptor: VisibleSegment {
            VisibleSegment(
                compTrackID: compTrackID,
                start: timeRange.start.seconds,
                transitionStart: transitionRange?.start.seconds,
                transitionEnd: transitionRange?.end.seconds,
                transitionType: transitionType)
        }
    }

    // MARK: - Render planning

    /// The minimal description of a clip visible during one instruction interval,
    /// used to decide how to composite it. Pure value type so the planning logic
    /// is unit-testable without an `AVComposition`.
    struct VisibleSegment {
        let compTrackID: CMPersistentTrackID
        /// Effective start of the clip.
        let start: Double
        /// The clip's incoming-transition interval, if any.
        let transitionStart: Double?
        let transitionEnd: Double?
        let transitionType: TransitionType?
    }

    /// A planned composite step, by composition-track id, bottom-to-top.
    enum PlannedUnit: Equatable {
        case layer(CMPersistentTrackID)
        case transition(outgoing: CMPersistentTrackID, incoming: CMPersistentTrackID, type: TransitionType)
    }

    /// Decides, for one project track, how to composite the clips visible at
    /// `midpoint`. When transitions overlap (a chain of three or more clips), the
    /// *topmost* active transition wins, blending the incoming clip with its
    /// immediate predecessor; any earlier still-visible clips render underneath
    /// so the newest clip is never dropped (which would "pop" in).
    static func planUnits(visible: [VisibleSegment], midpoint: Double) -> [PlannedUnit] {
        func transitionActive(_ seg: VisibleSegment) -> Bool {
            guard let start = seg.transitionStart, let end = seg.transitionEnd else { return false }
            return start <= midpoint && midpoint < end
        }

        if let incoming = visible.last(where: transitionActive),
           let type = incoming.transitionType,
           let outgoing = visible.filter({ $0.start < incoming.start }).max(by: { $0.start < $1.start }) {
            var result: [PlannedUnit] = []
            // Earlier clips still on screen render beneath the transition.
            for seg in visible where seg.compTrackID != incoming.compTrackID && seg.compTrackID != outgoing.compTrackID {
                result.append(.layer(seg.compTrackID))
            }
            result.append(.transition(outgoing: outgoing.compTrackID, incoming: incoming.compTrackID, type: type))
            return result
        }

        return visible.map { .layer($0.compTrackID) }
    }

    static func build(project: Project, showSkinMask: Bool = false) async throws -> BuiltComposition? {
        let composition = AVMutableComposition()
        let renderSize = project.renderSize

        // Project-wide transition cuts ripple every track so linked A/V stays
        // in sync; the rendered timeline shortens by the total overlap.
        let cuts = TransitionLayout.cuts(videoTracks: project.videoTracks)

        // Each project video track expands into a pool of composition tracks so a
        // transition's two clips can overlap on screen (A/B-roll). Clips are
        // packed greedily onto the first free composition track, so overlapping
        // clips never share one — robust to any chain of transitions.
        // `projectTrackSegments` preserves bottom-to-top order.
        var projectTrackSegments: [[VideoSegment]] = []

        for projectTrack in project.videoTracks {
            // Each pool entry tracks a composition track and the effective end of
            // its last-placed piece.
            var pool: [(track: AVMutableCompositionTrack, lastEnd: CMTime)] = []

            var segments: [VideoSegment] = []
            let ordered = projectTrack.clips.sorted { $0.timelineStart < $1.timelineStart }
            let overlaps = TransitionLayout.orderedOverlaps(ordered)
            for (clipIndex, clip) in ordered.enumerated() {
                guard let media = project.media(for: clip.mediaID), media.hasVideo else { continue }
                let sourceTracks = try await media.asset.loadTracks(withMediaType: .video)
                guard let sourceTrack = sourceTracks.first else { continue }

                let transform = fitTransform(
                    naturalSize: media.naturalSize,
                    preferredTransform: media.preferredTransform,
                    into: renderSize)

                // A clip may be split into pieces where it spans another track's
                // transition cut; each piece is packed onto the first free track.
                for piece in TransitionLayout.pieces(for: clip, overlap: overlaps[clipIndex], cuts: cuts) {
                    let start = piece.effectiveStart
                    let poolIndex: Int
                    if let free = pool.firstIndex(where: { $0.lastEnd <= start }) {
                        poolIndex = free
                    } else {
                        guard let newTrack = composition.addMutableTrack(
                            withMediaType: .video,
                            preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                        pool.append((newTrack, .zero))
                        poolIndex = pool.count - 1
                    }
                    let compTrack = pool[poolIndex].track
                    try compTrack.insertTimeRange(piece.sourceRange, of: sourceTrack, at: start)
                    pool[poolIndex].lastEnd = piece.effectiveEnd

                    segments.append(VideoSegment(
                        clipID: clip.id,
                        compTrackID: compTrack.trackID,
                        timeRange: CMTimeRange(start: start, duration: piece.duration),
                        transform: transform,
                        opacity: clip.opacity,
                        effects: clip.effects,
                        transitionRange: piece.transitionRange,
                        transitionType: piece.overlap > .zero ? clip.transition?.type : nil,
                        showSkinMask: showSkinMask,
                        clipStartTime: clip.timelineStart,
                        sourceRange: piece.sourceRange))
                }
            }
            projectTrackSegments.append(segments)
        }

        // Audio: split clips at cuts and place each piece on its own composition
        // track so rippled overlaps mix instead of corrupting one track, then
        // crossfade the overlaps so transitions stay smooth and in sync.
        var audioMixParameters: [AVMutableAudioMixInputParameters] = []
        var hasAudioCrossfade = false
        for projectTrack in project.audioTracks where !projectTrack.isMuted {
            var placed: [(track: AVMutableCompositionTrack, piece: TransitionLayout.Piece)] = []
            let ordered = projectTrack.clips.sorted { $0.timelineStart < $1.timelineStart }
            for clip in ordered {
                guard let media = project.media(for: clip.mediaID), media.hasAudio else { continue }
                let sourceTracks = try await media.asset.loadTracks(withMediaType: .audio)
                guard let sourceTrack = sourceTracks.first else { continue }
                for piece in TransitionLayout.pieces(for: clip, overlap: .zero, cuts: cuts) {
                    guard let compTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    try compTrack.insertTimeRange(piece.sourceRange, of: sourceTrack, at: piece.effectiveStart)
                    placed.append((compTrack, piece))
                }
            }

            placed.sort { $0.piece.effectiveStart < $1.piece.effectiveStart }
            for index in placed.indices {
                let piece = placed[index].piece
                let params = AVMutableAudioMixInputParameters(track: placed[index].track)
                let leadOverlap = index > 0
                    ? CMTimeMaximum(.zero, placed[index - 1].piece.effectiveEnd - piece.effectiveStart) : .zero
                let trailOverlap = index < placed.count - 1
                    ? CMTimeMaximum(.zero, piece.effectiveEnd - placed[index + 1].piece.effectiveStart) : .zero

                if leadOverlap > .zero {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                         timeRange: CMTimeRange(start: piece.effectiveStart, duration: leadOverlap))
                    hasAudioCrossfade = true
                } else {
                    params.setVolume(1, at: piece.effectiveStart)
                }
                if trailOverlap > .zero {
                    params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: piece.effectiveEnd - trailOverlap, duration: trailOverlap))
                    hasAudioCrossfade = true
                }
                audioMixParameters.append(params)
            }
        }

        let captionTracks = project.captionTracks.filter { !$0.isMuted }

        // Known limitation: a caption that ends past the last AV clip is
        // truncated to the AV duration on preview / export. Extending via
        // `AVMutableComposition.insertEmptyTimeRange` did not reliably update
        // `composition.duration` on macOS 26; the proper fix is to insert a
        // placeholder source media (a tiny black/silent .mov) into the
        // composition for the tail. Tracked as a follow-up; see Phase 30
        // spec's "Known limitations".
        let totalDuration = composition.duration
        guard totalDuration > .zero else { return nil }

        let videoComposition = try await makeVideoComposition(
            composition: composition,
            projectTrackSegments: projectTrackSegments,
            captionTracks: captionTracks,
            totalDuration: totalDuration,
            renderSize: renderSize,
            frameRate: project.frameRate)

        let audioMix: AVAudioMix?
        if hasAudioCrossfade {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioMixParameters
            audioMix = mix
        } else {
            audioMix = nil
        }

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: totalDuration.seconds)
    }

    // MARK: - Video composition

    /// Builds non-overlapping custom instructions covering the timeline. For
    /// each interval between segment boundaries we emit one instruction whose
    /// render units describe what each project track shows — a single layer, or
    /// a transition blend of its two overlapping clips.
    private static func makeVideoComposition(
        composition: AVComposition,
        projectTrackSegments: [[VideoSegment]],
        captionTracks: [CaptionTrack],
        totalDuration: CMTime,
        renderSize: CGSize,
        frameRate: Double) async throws -> AVVideoComposition? {

        let hasAnySegment = projectTrackSegments.contains { !$0.isEmpty }
        guard hasAnySegment else { return nil }

        // Collect and sort every distinct boundary time, including overlap edges
        // and caption-line edges so each line's enter / exit lands on an
        // instruction boundary (the compositor still re-evaluates animation per
        // frame inside an interval).
        var boundarySet = Set<Double>([0, totalDuration.seconds])
        for segments in projectTrackSegments {
            for seg in segments {
                boundarySet.insert(seg.timeRange.start.seconds)
                boundarySet.insert(seg.timeRange.end.seconds)
                if let overlap = seg.transitionRange {
                    boundarySet.insert(overlap.start.seconds)
                    boundarySet.insert(overlap.end.seconds)
                }
            }
        }
        for track in captionTracks {
            for line in track.lines {
                boundarySet.insert(line.range.start.seconds)
                boundarySet.insert(line.range.end.seconds)
            }
        }
        let boundaries = boundarySet.sorted()

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for i in 0..<(boundaries.count - 1) {
            let start = CMTime(seconds: boundaries[i], preferredTimescale: 600)
            let end = CMTime(seconds: boundaries[i + 1], preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)
            guard range.duration > .zero else { continue }

            let midpoint = boundaries[i] + (boundaries[i + 1] - boundaries[i]) / 2

            // Build units bottom-to-top so the compositor composites correctly.
            var units: [RenderUnit] = []
            for segments in projectTrackSegments {
                let visible = segments.filter { $0.contains(midpoint) }
                guard !visible.isEmpty else { continue }
                let byTrack = Dictionary(uniqueKeysWithValues: visible.map { ($0.compTrackID, $0) })

                for planned in planUnits(visible: visible.map(\.descriptor), midpoint: midpoint) {
                    switch planned {
                    case .layer(let trackID):
                        guard let seg = byTrack[trackID] else { continue }
                        units.append(.layer(seg.layer))
                    case .transition(let outID, let inID, let type):
                        guard let outSeg = byTrack[outID], let inSeg = byTrack[inID],
                              let overlap = inSeg.transitionRange else { continue }
                        units.append(.transition(outgoing: outSeg.layer, incoming: inSeg.layer,
                                                 type: type, overlap: overlap))
                    }
                }
            }

            let captionsForInterval = activeCaptionItems(
                in: captionTracks, midpoint: midpoint)
            instructions.append(EffectCompositionInstruction(
                timeRange: range, units: units, captions: captionsForInterval))
        }

        var config = try await AVVideoComposition.Configuration(for: composition)
        config.renderSize = renderSize
        config.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        config.customVideoCompositorClass = EffectCompositor.self
        config.instructions = instructions
        return AVVideoComposition(configuration: config)
    }

    /// Lines from each unmuted caption track active at `midpoint`. Track order
    /// is bottom-to-top so later-listed tracks render above earlier ones — matches
    /// the video-track stacking convention.
    private static func activeCaptionItems(in tracks: [CaptionTrack],
                                           midpoint: Double) -> [CaptionRenderItem] {
        var items: [CaptionRenderItem] = []
        for track in tracks {
            for line in track.lines {
                let start = line.range.start.seconds
                let end = line.range.end.seconds
                guard start <= midpoint, midpoint < end else { continue }
                items.append(CaptionRenderItem(
                    lineID: line.id,
                    text: line.text,
                    words: line.words,
                    style: line.style ?? track.defaultStyle,
                    range: line.range))
            }
        }
        return items
    }

    // MARK: - Geometry

    /// Aspect-fit a source frame (after its preferred orientation transform) into
    /// the render canvas, centered.
    private static func fitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        into renderSize: CGSize) -> CGAffineTransform {

        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { return preferredTransform }

        // Normalize so the oriented frame's origin sits at (0, 0).
        var transform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))

        let scale = min(renderSize.width / orientedSize.width,
                        renderSize.height / orientedSize.height)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let tx = (renderSize.width - scaledSize.width) / 2
        let ty = (renderSize.height - scaledSize.height) / 2
        transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))

        return transform
    }
}
