import Foundation
import AVFoundation
import CoreGraphics
import LocalCutCore

/// The product of building a project: an immutable composition plus the video
/// composition that describes how its video layers are transformed and stacked.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
    let audioCleanup: VoiceCleanupSettings
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
        let transitionWipeAngle: Double?
        let showSkinMask: Bool
        let clipSourceStart: CMTime
        let sourceRange: CMTimeRange
        let orderingStart: CMTime

        var layer: CompositorLayer {
            CompositorLayer(clipID: clipID, trackID: compTrackID, transform: transform, opacity: opacity, effects: effects, showSkinMask: showSkinMask, clipSourceStart: clipSourceStart, sourceRange: sourceRange, timeRange: timeRange)
        }

        func contains(_ seconds: Double) -> Bool {
            timeRange.start.seconds <= seconds && seconds < timeRange.end.seconds
        }

        var descriptor: VisibleSegment {
            VisibleSegment(
                compTrackID: compTrackID,
                start: timeRange.start.seconds,
                orderingStart: orderingStart.seconds,
                transitionStart: transitionRange?.start.seconds,
                transitionEnd: transitionRange?.end.seconds,
                transitionType: transitionType,
                transitionWipeAngle: transitionWipeAngle)
        }
    }

    // MARK: - Render planning
    //
    // VisibleSegment, PlannedUnit, and planUnits() are defined in LocalCutCore.

    static func build(project: Project, showSkinMask: Bool = false,
                      overlaySourceRegistryID: UUID? = nil) async throws -> BuiltComposition? {
        let composition = AVMutableComposition()
        let renderSize = project.renderSize

        // Project-wide transition cuts ripple every track so linked A/V stays
        // in sync; the rendered timeline shortens by the total overlap.
        let cuts = TransitionLayout.cuts(videoTracks: project.videoTracks.map(\.clips))

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
                let sourceSampleDuration = try? await sourceTrack.load(.minFrameDuration)

                let transform = fitTransform(
                    naturalSize: media.naturalSize,
                    preferredTransform: media.preferredTransform,
                    into: renderSize)

                // A clip may be split into pieces where it spans another track's
                // transition cut; the tail piece ripples left under the head, so
                // pieces can overlap. Pack each piece onto the first free pool
                // track so overlapping pieces — including a retimed clip's own
                // halves — never share a composition track and corrupt each other
                // when scaled.
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
                    pool[poolIndex].lastEnd = piece.effectiveEnd

                    let remapSegments = try insertRetimedPiece(
                        clip: clip,
                        piece: piece,
                        sourceTrack: sourceTrack,
                        sourceSampleDuration: sourceSampleDuration,
                        into: compTrack)
                    for remapSegment in remapSegments {
                        let segmentStart = start + (remapSegment.outputOffset - piece.outputOffset)
                        segments.append(VideoSegment(
                            clipID: clip.id,
                            compTrackID: compTrack.trackID,
                            timeRange: CMTimeRange(start: segmentStart,
                                                   duration: remapSegment.outputDuration),
                            transform: transform,
                            opacity: clip.opacity,
                            effects: clip.effects,
                            transitionRange: piece.transitionRange,
                            transitionType: piece.overlap > .zero ? clip.transition?.type : nil,
                            transitionWipeAngle: piece.overlap > .zero ? clip.transition?.wipeAngle : nil,
                            showSkinMask: showSkinMask,
                            clipSourceStart: clip.sourceStart,
                            sourceRange: remapSegment.sourceRange,
                            orderingStart: piece.effectiveStart))
                    }
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
        var hasTimePitchContribution = false
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
                let audioSampleDuration = try? await sourceTrack.load(.minFrameDuration)
                let sourceSampleDuration: CMTime?
                if media.hasVideo,
                   let videoSourceTracks = try? await media.asset.loadTracks(withMediaType: .video),
                   let videoSourceTrack = videoSourceTracks.first {
                    sourceSampleDuration = (try? await videoSourceTrack.load(.minFrameDuration))
                        ?? audioSampleDuration
                } else {
                    sourceSampleDuration = audioSampleDuration
                }
                if !clip.volumeEnvelope.isEmpty { hasBusContribution = true }
                for piece in TransitionLayout.pieces(for: clip, overlap: .zero, cuts: cuts) {
                    guard let compTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    _ = try insertRetimedPiece(
                        clip: clip,
                        piece: piece,
                        sourceTrack: sourceTrack,
                        sourceSampleDuration: sourceSampleDuration,
                        into: compTrack)
                    placed.append((compTrack, clip, piece))
                }
            }

            placed.sort { $0.piece.effectiveStart < $1.piece.effectiveStart }
            for index in placed.indices {
                let piece = placed[index].piece
                let clip = placed[index].clip
                let params = AVMutableAudioMixInputParameters(track: placed[index].track)
                if clip.hasTimeRemap {
                    // Pitch-preserving stretch uses the chosen spectral/time-domain
                    // algorithm; with preservation off we force `.varispeed` so the
                    // audio bends with the speed (chipmunk / slow-mo). Either way a
                    // retimed clip needs an audio mix, so flag the contribution.
                    params.audioTimePitchAlgorithm = clip.preservePitch
                        ? clip.pitchAlgorithm.avFoundationAlgorithm
                        : .varispeed
                    hasTimePitchContribution = true
                }
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

        // Insert a black-frame filler track wherever the project has visual
        // activity (captions or animated overlays) but no video clip to render
        // it over. Comparing against the last VIDEO segment end (not
        // `composition.duration`) matters because an audio track longer than
        // the final video clip already pushes `composition.duration` past the
        // last video frame; without this we would silently miss captions and
        // overlays that sit over the audio-only gap. Codex P1.
        //
        // `insertEmptyTimeRange` does not reliably push `composition.duration`
        // forward, so we insert real frames. The filler's track doubles as
        // the *required source* for tail instructions so AVFoundation
        // schedules the compositor across that interval; without a required
        // source the export pipeline hangs waiting for a frame.
        //
        // For very long tails (multi-minute captions / bad subtitle timestamps
        // / overlay graphics) we encode only a short filler asset and
        // loop-insert it into the composition track so a 30-minute tail does
        // not make the editor block on writing tens of thousands of frames.
        // Codex P2 (cap filler generation).
        let captionEnd = captionTracks.reduce(CMTime.zero) {
            CMTimeMaximum($0, $1.endTime)
        }
        let overlayEnd = project.overlays.reduce(CMTime.zero) { current, overlay in
            overlay.timelineEnd.isNumeric ? CMTimeMaximum(current, overlay.timelineEnd) : current
        }
        let visualTailEnd = CMTimeMaximum(captionEnd, overlayEnd)
        let lastVideoEnd = projectTrackSegments.flatMap { $0 }
            .reduce(CMTime.zero) { CMTimeMaximum($0, $1.timeRange.end) }

        var fillerTailRange: CMTimeRange?
        var fillerTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        if visualTailEnd.isNumeric, lastVideoEnd.isNumeric, visualTailEnd > lastVideoEnd {
            let tailStart = lastVideoEnd
            let tailDuration = visualTailEnd - tailStart
            // Generate at most `fillerChunkSeconds` of source media; longer
            // tails reuse the same chunk via repeated `insertTimeRange`s.
            let chunkSeconds = CMTime(seconds: fillerChunkSeconds,
                                      preferredTimescale: 600)
            let filler = try await CaptionTailFiller.asset(
                renderSize: renderSize,
                frameRate: project.frameRate,
                minimumDuration: chunkSeconds)
            let fillerVideoTracks = try await filler.loadTracks(withMediaType: .video)
            let fillerAssetDuration = try await filler.load(.duration).sanitized
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

        // Every cross-dissolve renders through the custom compositor's additive
        // blend (`EffectCompositor.crossDissolve` — RGB·(1-p) + RGB·p, which
        // holds midpoint brightness for opaque inputs). An earlier draft also
        // shipped a fast-path that routed cross-dissolves through a standard
        // layer-instruction opacity ramp when no effects / wipes / captions
        // were present, but an opacity ramp does source-over alpha
        // compositing — at progress 0.5 it yields
        // `(2·incoming + outgoing)/3` with α=0.75, not the additive `(A+B)/2`
        // at α=1. Switching paths on the same project would have produced
        // visibly different cross-dissolves, violating T3.1 "preview matches
        // export". The layer-instruction helper is retained in
        // `crossDissolveLayerInstructions(...)` as tested spec-compliance
        // infrastructure (Codex P2) for a future native-export path.
        let videoComposition = try await makeVideoComposition(
            composition: composition,
            projectTrackSegments: projectTrackSegments,
            captionTracks: captionTracks,
            overlays: project.overlays,
            totalDuration: totalDuration,
            renderSize: renderSize,
            frameRate: project.frameRate,
            fillerTrackID: fillerTrackID,
            fillerTailRange: fillerTailRange,
            overlaySourceRegistryID: overlaySourceRegistryID,
            workingColourSpace: project.workingColourSpace)

        let audioMix: AVAudioMix?
        if hasAudioCrossfade || hasBusContribution || hasTimePitchContribution {
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
            audioCleanup: project.voiceCleanup,
            duration: totalDuration.seconds)
    }

    /// Inserts every speed-plan subsegment for `piece` into one composition
    /// track, scaling immediately after each insert. Later subsegments are not
    /// present yet, so `scaleTimeRange` cannot shift unrelated clips; ramped
    /// video clips still get dedicated tracks at the call site to keep that
    /// invariant true across transition pieces.
    @discardableResult
    private static func insertRetimedPiece(clip: Clip,
                                           piece: TransitionLayout.Piece,
                                           sourceTrack: AVAssetTrack,
                                           sourceSampleDuration: CMTime?,
                                           into compTrack: AVMutableCompositionTrack)
        throws -> [TimeRemapSegment] {
        let rawSegments = TimeRemapping.segmentPlan(for: clip, sourceRange: piece.sourceRange)
        let remapSegments: [TimeRemapSegment]
        if let sourceSampleDuration, sourceSampleDuration.isNumeric, sourceSampleDuration > .zero {
            remapSegments = TimeRemapping.snapSegmentPlan(
                rawSegments,
                toSourceSampleDuration: sourceSampleDuration)
        } else {
            remapSegments = rawSegments
        }
        for segment in remapSegments {
            let start = piece.effectiveStart + (segment.outputOffset - piece.outputOffset)
            try compTrack.insertTimeRange(segment.sourceRange, of: sourceTrack, at: start)
            if abs((segment.outputDuration - segment.sourceRange.duration).seconds) > 0.000_001 {
                compTrack.scaleTimeRange(
                    CMTimeRange(start: start, duration: segment.sourceRange.duration),
                    toDuration: segment.outputDuration)
            }
        }
        return remapSegments
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

        let clipDuration = clip.outputDuration
        let (fadeIn, fadeOut) = envelope.clampedFades(clipDuration: clipDuration)
        // Clip-relative offset of this piece in output time. Volume envelopes
        // are timeline gestures, so they follow the retimed clip length instead
        // of the raw source span.
        let pieceClipRelOffset = piece.outputOffset
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

    // MARK: - Video composition
    //
    // subRampVolumes() and fitTransform() are defined in LocalCutCore.

    /// Builds non-overlapping custom instructions covering the timeline. For
    /// each interval between segment boundaries we emit one instruction whose
    /// render units describe what each project track shows — a single layer, or
    /// a transition blend of its two overlapping clips.
    private static func makeVideoComposition(
        composition: AVComposition,
        projectTrackSegments: [[VideoSegment]],
        captionTracks: [CaptionTrack],
        overlays: [OverlayClip],
        totalDuration: CMTime,
        renderSize: CGSize,
        frameRate: Double,
        fillerTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid,
        fillerTailRange: CMTimeRange? = nil,
        overlaySourceRegistryID: UUID? = nil,
        workingColourSpace: WorkingColourSpace) async throws -> AVVideoComposition? {

        // The filler counts as "something to render" for the tail interval, so
        // a caption-only or audio-only-with-captions project still gets a
        // video composition (and therefore its caption burn-in). Without this,
        // a project consisting of just an audio file + an SRT would build to
        // a silent black tail with no captions on screen. Codex P2 (filler
        // path).
        let hasAnySegment = projectTrackSegments.contains { !$0.isEmpty }
            || fillerTrackID != kCMPersistentTrackID_Invalid
            || !overlays.isEmpty
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
        for overlay in overlays {
            boundarySet.insert(overlay.timelineStart.seconds)
            boundarySet.insert(overlay.timelineEnd.seconds)
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
                    case .transition(let outID, let inID, let type, let wipeAngle):
                        guard let outSeg = byTrack[outID], let inSeg = byTrack[inID],
                              let overlap = inSeg.transitionRange else { continue }
                        units.append(.transition(outgoing: outSeg.layer, incoming: inSeg.layer,
                                                 type: type, wipeAngle: wipeAngle, overlap: overlap))
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
                    clipSourceStart: tail.start,
                    sourceRange: tail,
                    timeRange: tail)))
            }

            let captionsForInterval = activeCaptionItems(
                in: captionTracks, midpoint: midpoint)
            let overlaysForInterval = activeOverlayItems(
                in: overlays, midpoint: midpoint)
            instructions.append(EffectCompositionInstruction(
                timeRange: range, units: units, captions: captionsForInterval,
                overlays: overlaysForInterval,
                overlaySourceRegistryID: overlaySourceRegistryID,
                frameRate: frameRate,
                workingColourSpace: workingColourSpace))
        }

        // Overlay frame sources are registered by EditorModel.registerOverlaySources()
        // before CompositionBuilder.build() is called — do not clear them here.

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
                    styleKeyframes: line.styleKeyframes,
                    range: line.range))
            }
        }
        return items
    }

    /// Overlay clips active at `midpoint`. Ordered bottom-to-top matching the
    /// project's overlay array order.
    private static func activeOverlayItems(in overlays: [OverlayClip],
                                           midpoint: Double) -> [OverlayRenderItem] {
        var items: [OverlayRenderItem] = []
        for overlay in overlays {
            let start = overlay.timelineStart.seconds
            let end = overlay.timelineEnd.seconds
            guard start <= midpoint, midpoint < end else { continue }
            items.append(OverlayRenderItem(
                overlayID: overlay.id,
                sourceType: overlay.sourceType,
                range: CMTimeRange(start: overlay.timelineStart, duration: overlay.duration),
                positionOffset: overlay.positionOffset,
                scale: overlay.scale,
                rotation: overlay.rotation,
                opacity: overlay.opacity,
                endAction: overlay.endAction))
        }
        return items
    }

    // MARK: - Cross-dissolve layer instructions (T1.2 feature-transitions)

    /// The AVFoundation-native expression of a cross-dissolve as two
    /// `AVVideoCompositionLayerInstruction`s with an opacity ramp over the
    /// overlap interval, each built from an
    /// `AVVideoCompositionLayerInstruction.Configuration` (the macOS 26
    /// replacement for the deprecated mutable layer-instruction API).
    ///
    /// Production cross-dissolves run through `EffectCompositor.crossDissolve`
    /// (additive blend — midpoint `(A+B)/2` with α=1), not this helper. An
    /// earlier draft did wire a fast path that called this helper when a
    /// project consisted only of cross-dissolves with no effects / captions /
    /// working-colour overrides, but `setOpacityRamp` does source-over alpha
    /// compositing (midpoint `(2B+A)/3` with α=0.75) — switching paths on the
    /// same project would have produced visibly different cross-dissolves and
    /// violated T3.1 "preview matches export" the moment a user added a
    /// colour effect. The helper is retained as:
    ///   1. Spec-compliance infrastructure (Codex P2 — feature-transitions T1.2
    ///      explicitly calls out an opacity ramp on a layer instruction),
    ///   2. A reference shape for a future native-export path that doesn't
    ///      run through the custom compositor.
    /// Exercised in production-equivalent form by the
    /// `crossDissolveLayerRamps` regression test in `TransitionsTests.swift`.
    static func crossDissolveLayerInstructions(
        outgoingTrackID: CMPersistentTrackID,
        incomingTrackID: CMPersistentTrackID,
        outgoingTransform: CGAffineTransform,
        incomingTransform: CGAffineTransform,
        overlap: CMTimeRange
    ) -> (outgoing: AVVideoCompositionLayerInstruction,
          incoming: AVVideoCompositionLayerInstruction) {

        var outgoing = AVVideoCompositionLayerInstruction.Configuration(trackID: outgoingTrackID)
        outgoing.setTransform(outgoingTransform, at: overlap.start)
        outgoing.addOpacityRamp(.init(timeRange: overlap, start: 1, end: 0))

        var incoming = AVVideoCompositionLayerInstruction.Configuration(trackID: incomingTrackID)
        incoming.setTransform(incomingTransform, at: overlap.start)
        incoming.addOpacityRamp(.init(timeRange: overlap, start: 0, end: 1))

        return (AVVideoCompositionLayerInstruction(configuration: outgoing),
                AVVideoCompositionLayerInstruction(configuration: incoming))
    }

}
