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

    /// Upper bound on a single filler-asset encode. Longer caption tails are
    /// covered by repeatedly inserting this short chunk into the composition
    /// track via `insertTimeRange`, so the on-disk filler stays small no
    /// matter how long the tail is.
    private static let fillerChunkSeconds: Double = 5

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
        //
        // P16 master-bus extension: when the bus or per-clip envelopes contribute
        // anything beyond defaults, ramps and baselines are multiplied through
        // the master/track gain and per-clip envelope. A default project (master
        // gain 1, empty track inputs, empty envelopes) produces the identical
        // ramp set as before the bus existed — the audio mix is still nil unless
        // a crossfade is actually present.
        var audioMixParameters: [AVMutableAudioMixInputParameters] = []
        var hasAudioCrossfade = false
        var hasBusContribution = false
        for projectTrack in project.audioTracks where !projectTrack.isMuted {
            let trackInput = project.trackInputs.first(where: { $0.id == projectTrack.id })
            let baseline = AudioBusMixing.baselineVolume(masterGain: project.masterGain,
                                                         trackInput: trackInput)
            if baseline != 1 { hasBusContribution = true }

            var placed: [(track: AVMutableCompositionTrack, clip: Clip,
                          piece: TransitionLayout.Piece)] = []
            let ordered = projectTrack.clips.sorted { $0.timelineStart < $1.timelineStart }
            for clip in ordered {
                guard let media = project.media(for: clip.mediaID), media.hasAudio else { continue }
                let sourceTracks = try await media.asset.loadTracks(withMediaType: .audio)
                guard let sourceTrack = sourceTracks.first else { continue }
                if !clip.volumeEnvelope.isEmpty { hasBusContribution = true }
                for piece in TransitionLayout.pieces(for: clip, overlap: .zero, cuts: cuts) {
                    guard let compTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    try compTrack.insertTimeRange(piece.sourceRange, of: sourceTrack, at: piece.effectiveStart)
                    placed.append((compTrack, clip, piece))
                }
            }

            placed.sort { $0.piece.effectiveStart < $1.piece.effectiveStart }
            for index in placed.indices {
                let piece = placed[index].piece
                let clip = placed[index].clip
                let params = AVMutableAudioMixInputParameters(track: placed[index].track)
                let leadOverlap = index > 0
                    ? CMTimeMaximum(.zero, placed[index - 1].piece.effectiveEnd - piece.effectiveStart) : .zero
                let trailOverlap = index < placed.count - 1
                    ? CMTimeMaximum(.zero, piece.effectiveEnd - placed[index + 1].piece.effectiveStart) : .zero
                // A clip can be split into multiple pieces by another track's
                // transition cut. Fades only apply at the clip's actual head /
                // tail (not at every internal split), so flag the first / last
                // piece of each clip.
                let isFirstPieceOfClip = index == 0
                    || placed[index - 1].clip.id != clip.id
                let isLastPieceOfClip = index == placed.count - 1
                    || placed[index + 1].clip.id != clip.id

                // Transition crossfades are written first, baseline-multiplied,
                // so a default project (baseline = 1) produces the exact same
                // ramp values as before. The R6.5 regression test guards this.
                if leadOverlap > .zero {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: baseline,
                                         timeRange: CMTimeRange(start: piece.effectiveStart, duration: leadOverlap))
                    hasAudioCrossfade = true
                } else {
                    params.setVolume(baseline, at: piece.effectiveStart)
                }
                if trailOverlap > .zero {
                    params.setVolumeRamp(fromStartVolume: baseline, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: piece.effectiveEnd - trailOverlap, duration: trailOverlap))
                    hasAudioCrossfade = true
                }

                applyVolumeEnvelope(clip.volumeEnvelope,
                                    on: params,
                                    clip: clip,
                                    piece: piece,
                                    isFirstPieceOfClip: isFirstPieceOfClip,
                                    isLastPieceOfClip: isLastPieceOfClip,
                                    leadOverlap: leadOverlap,
                                    trailOverlap: trailOverlap,
                                    baseline: baseline)

                audioMixParameters.append(params)
            }
        }

        let captionTracks = project.captionTracks.filter { !$0.isMuted }

        // Insert a black-frame filler track wherever the project has caption
        // activity but no video to render it over. Comparing against the last
        // VIDEO segment end (not `composition.duration`) matters because an
        // audio track longer than the final video clip already pushes
        // `composition.duration` past the last video frame; without this we
        // would silently miss every caption that sits over the audio-only
        // gap. Codex P1.
        //
        // `insertEmptyTimeRange` does not reliably push `composition.duration`
        // forward, so we insert real frames. The filler's track doubles as
        // the *required source* for tail instructions so AVFoundation
        // schedules the compositor across that interval; without a required
        // source the export pipeline hangs waiting for a frame.
        //
        // For very long tails (multi-minute captions / bad subtitle
        // timestamps) we encode only a short filler asset and loop-insert it
        // into the composition track so a 30-minute caption tail does not
        // make the editor block on writing tens of thousands of frames.
        // Codex P2 (cap filler generation).
        let captionEnd = captionTracks.reduce(CMTime.zero) {
            CMTimeMaximum($0, $1.endTime)
        }
        let lastVideoEnd = projectTrackSegments.flatMap { $0 }
            .reduce(CMTime.zero) { CMTimeMaximum($0, $1.timeRange.end) }

        var fillerTailRange: CMTimeRange?
        var fillerTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        if captionEnd.isNumeric, lastVideoEnd.isNumeric, captionEnd > lastVideoEnd {
            let tailStart = lastVideoEnd
            let tailDuration = captionEnd - tailStart
            // Generate at most `fillerChunkSeconds` of source media; longer
            // tails reuse the same chunk via repeated `insertTimeRange`s.
            let chunkSeconds = CMTime(seconds: fillerChunkSeconds,
                                      preferredTimescale: 600)
            let filler = try await CaptionTailFiller.asset(
                renderSize: renderSize,
                frameRate: project.frameRate,
                minimumDuration: chunkSeconds)
            let fillerVideoTracks = try await filler.loadTracks(withMediaType: .video)
            let fillerAssetDuration = try await filler.load(.duration)
            if let fillerVideoSource = fillerVideoTracks.first,
               fillerAssetDuration > .zero,
               let fillerCompTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) {
                // Insert in chunks of at most `fillerAssetDuration` so the
                // encoded source can be tiny while still covering an
                // arbitrarily long tail.
                var insertAt = tailStart
                var remaining = tailDuration
                while remaining > .zero {
                    let chunk = CMTimeMinimum(fillerAssetDuration, remaining)
                    guard chunk > .zero else { break }
                    try fillerCompTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: chunk),
                        of: fillerVideoSource,
                        at: insertAt)
                    insertAt = insertAt + chunk
                    remaining = remaining - chunk
                }
                fillerTrackID = fillerCompTrack.trackID
                fillerTailRange = CMTimeRange(start: tailStart, duration: tailDuration)
            }
        }

        let totalDuration = composition.duration
        guard totalDuration > .zero else { return nil }

        let videoComposition = try await makeVideoComposition(
            composition: composition,
            projectTrackSegments: projectTrackSegments,
            captionTracks: captionTracks,
            totalDuration: totalDuration,
            renderSize: renderSize,
            frameRate: project.frameRate,
            fillerTrackID: fillerTrackID,
            fillerTailRange: fillerTailRange,
            workingColourSpace: project.workingColourSpace)

        let audioMix: AVAudioMix?
        if hasAudioCrossfade || hasBusContribution {
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

    // MARK: - Volume envelope application (P16)

    /// Writes the clip's `VolumeEnvelope` ramps into `params`, baseline-multiplied
    /// so master/track gain still apply. Handles four awkward shapes:
    ///
    /// - **Clip-relative ramps.** `VolumeEnvelope.Ramp.range` is in clip-relative
    ///   time (so the automation moves with the clip on drag/trim); we project it
    ///   to effective time via each piece's clip-relative offset.
    /// - **Multi-piece clips.** A clip spanning another track's transition cut is
    ///   split into multiple pieces by `TransitionLayout.pieces`. Each piece only
    ///   covers a sub-range of clip-relative time, so we intersect ramps with that
    ///   sub-range and emit partial ramps. Fades go on the first / last piece only.
    /// - **Render-time fade clamp.** `fadeIn + fadeOut > clipDuration` ⇒ each fade
    ///   reduces to `clipDuration / 2` (see `VolumeEnvelope.clampedFades`).
    /// - **Transition crossfade conflicts.** Where a transition ramp already
    ///   occupies the head / tail of a piece, envelope writes inside that window
    ///   would overwrite the crossfade (last write wins in
    ///   `AVMutableAudioMixInputParameters`). We restrict envelope writes to the
    ///   non-transition portion of each piece so transitions remain authoritative
    ///   at the cut.
    private static func applyVolumeEnvelope(_ envelope: VolumeEnvelope,
                                            on params: AVMutableAudioMixInputParameters,
                                            clip: Clip,
                                            piece: TransitionLayout.Piece,
                                            isFirstPieceOfClip: Bool,
                                            isLastPieceOfClip: Bool,
                                            leadOverlap: CMTime,
                                            trailOverlap: CMTime,
                                            baseline: Float) {
        guard !envelope.isEmpty else { return }

        let clipDuration = clip.duration
        let (fadeIn, fadeOut) = envelope.clampedFades(clipDuration: clipDuration)
        // Clip-relative offset of this piece: how far into the clip's source it
        // starts. For a single-piece clip this is .zero.
        let pieceClipRelOffset = piece.sourceRange.start - clip.sourceStart
        let pieceClipRelRange = CMTimeRange(start: pieceClipRelOffset, duration: piece.duration)

        // Envelope ramps to write, in clip-relative coordinates with their final
        // (baseline-multiplied) endpoint volumes. Fades degrade to no-op when a
        // transition crossfade already covers the same boundary.
        var envelopeRamps: [(range: CMTimeRange, fromVolume: Float, toVolume: Float)] = []
        if fadeIn > .zero, isFirstPieceOfClip, leadOverlap == .zero {
            envelopeRamps.append((
                range: CMTimeRange(start: .zero, duration: fadeIn),
                fromVolume: 0,
                toVolume: baseline))
        }
        if fadeOut > .zero, isLastPieceOfClip, trailOverlap == .zero {
            envelopeRamps.append((
                range: CMTimeRange(start: clipDuration - fadeOut, duration: fadeOut),
                fromVolume: baseline,
                toVolume: 0))
        }
        for ramp in envelope.ramps {
            let clipFullRange = CMTimeRange(start: .zero, duration: clipDuration)
            guard let clamped = VolumeEnvelope.clampedRange(ramp.range, to: clipFullRange) else { continue }
            let (from, to) = subRampVolumes(
                fullRange: ramp.range,
                fullFrom: ramp.fromVolume * baseline,
                fullTo: ramp.toVolume * baseline,
                subRange: clamped)
            envelopeRamps.append((range: clamped, fromVolume: from, toVolume: to))
        }

        for er in envelopeRamps {
            // Intersect with this piece's clip-relative range so we only emit
            // the portion that actually plays out of this piece.
            let inPiece = er.range.intersection(pieceClipRelRange)
            guard inPiece.duration > .zero else { continue }

            // Avoid overwriting the transition crossfade ramps written above.
            // Trim envelope writes that fall inside [pieceStart, pieceStart+leadOverlap]
            // or [pieceEnd-trailOverlap, pieceEnd] (in clip-relative coordinates).
            var trimmed = inPiece
            if leadOverlap > .zero {
                let leadEndCR = pieceClipRelRange.start + leadOverlap
                if trimmed.start < leadEndCR {
                    let cut = CMTimeMinimum(leadEndCR - trimmed.start, trimmed.duration)
                    trimmed = CMTimeRange(start: trimmed.start + cut,
                                          duration: trimmed.duration - cut)
                }
            }
            if trailOverlap > .zero {
                let trailStartCR = pieceClipRelRange.end - trailOverlap
                if trimmed.end > trailStartCR {
                    let cut = CMTimeMinimum(trimmed.end - trailStartCR, trimmed.duration)
                    trimmed = CMTimeRange(start: trimmed.start,
                                          duration: trimmed.duration - cut)
                }
            }
            guard trimmed.duration > .zero else { continue }

            // Project clip-relative time back to this piece's effective time.
            let effStart = piece.effectiveStart + (trimmed.start - pieceClipRelOffset)
            let effRange = CMTimeRange(start: effStart, duration: trimmed.duration)
            let (from, to) = subRampVolumes(
                fullRange: er.range,
                fullFrom: er.fromVolume,
                fullTo: er.toVolume,
                subRange: trimmed)
            params.setVolumeRamp(fromStartVolume: from, toEndVolume: to, timeRange: effRange)
        }
    }

    /// Linearly interpolates `fullFrom` / `fullTo` over `fullRange` and returns
    /// the endpoint volumes that correspond to `subRange`. Used to emit partial
    /// ramps when an envelope ramp only intersects part of a piece.
    private static func subRampVolumes(fullRange: CMTimeRange,
                                       fullFrom: Float,
                                       fullTo: Float,
                                       subRange: CMTimeRange) -> (Float, Float) {
        let fullDur = fullRange.duration.seconds
        guard fullDur > 0 else { return (fullFrom, fullTo) }
        let t0 = (subRange.start - fullRange.start).seconds / fullDur
        let t1 = (subRange.end - fullRange.start).seconds / fullDur
        let from = fullFrom + (fullTo - fullFrom) * Float(t0)
        let to = fullFrom + (fullTo - fullFrom) * Float(t1)
        return (from, to)
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
        frameRate: Double,
        fillerTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid,
        fillerTailRange: CMTimeRange? = nil,
        workingColourSpace: WorkingColourSpace) async throws -> AVVideoComposition? {

        // The filler counts as "something to render" for the tail interval, so
        // a caption-only or audio-only-with-captions project still gets a
        // video composition (and therefore its caption burn-in). Without this,
        // a project consisting of just an audio file + an SRT would build to
        // a silent black tail with no captions on screen. Codex P2 (filler
        // path).
        let hasAnySegment = projectTrackSegments.contains { !$0.isEmpty }
            || fillerTrackID != kCMPersistentTrackID_Invalid
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

            // Tail intervals (past the last AV clip) have no clip segment, but
            // the export pipeline still needs a `requiredSourceTrackIDs` entry
            // to schedule the compositor — surface the filler as a layer so
            // its track ID flows into the instruction. The layer renders as
            // black; captions composite on top.
            if units.isEmpty,
               let tail = fillerTailRange,
               fillerTrackID != kCMPersistentTrackID_Invalid,
               tail.containsTime(CMTime(seconds: midpoint, preferredTimescale: 600)) {
                units.append(.layer(CompositorLayer(
                    clipID: UUID(),  // filler; no real clip
                    trackID: fillerTrackID,
                    transform: .identity,
                    opacity: 1,
                    effects: [],
                    showSkinMask: false,
                    clipStartTime: tail.start,
                    sourceRange: tail,
                    timeRange: tail)))
            }

            let captionsForInterval = activeCaptionItems(
                in: captionTracks, midpoint: midpoint)
            instructions.append(EffectCompositionInstruction(
                timeRange: range, units: units, captions: captionsForInterval,
                workingColourSpace: workingColourSpace))
        }

        var config = try await AVVideoComposition.Configuration(for: composition)
        config.renderSize = renderSize
        config.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        config.customVideoCompositorClass = EffectCompositor.self
        config.instructions = instructions
        // Declare the working-space tags on the AVVideoComposition itself so the
        // export pipeline copies them onto the encoded movie metadata even before
        // the per-frame buffer attachments arrive (R2.2).
        config.colorPrimaries = workingColourSpace.cvColorPrimaries as String
        config.colorTransferFunction = workingColourSpace.cvTransferFunction as String
        config.colorYCbCrMatrix = workingColourSpace.cvYCbCrMatrix as String
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
