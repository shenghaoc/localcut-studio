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
        let mediaID: UUID
        let compTrackID: CMPersistentTrackID
        let timeRange: CMTimeRange
        let transform: CGAffineTransform
        let opacity: Float
        let mask: ClipMaskShape
        let effects: [Effect]
        let transitionRange: CMTimeRange?
        let transitionType: TransitionType?
        let transitionWipeAngle: Double?
        let showSkinMask: Bool
        let clipSourceStart: CMTime
        let sourceRange: CMTimeRange
        let orderingStart: CMTime
        /// A25: Scene z-order for layout override sorting. Higher values
        /// render on top. Default 0 for non-layout segments.
        let zOrder: Int
        /// Phase 43: keyframed transform for zoom-n-pan animation.
        let transformKeyframes: Keyframed<Transform2D>

        var layer: CompositorLayer {
            CompositorLayer(clipID: clipID, trackID: compTrackID, transform: transform, opacity: opacity, mask: mask, effects: effects, showSkinMask: showSkinMask, clipSourceStart: clipSourceStart, sourceRange: sourceRange, timeRange: timeRange, transformKeyframes: transformKeyframes)
        }

        func contains(_ seconds: Double) -> Bool {
            timeRange.start.seconds <= seconds && seconds < timeRange.end.seconds
        }

        func withTimeRange(_ newRange: CMTimeRange) -> VideoSegment {
            VideoSegment(
                clipID: clipID, mediaID: mediaID, compTrackID: compTrackID,
                timeRange: newRange, transform: transform, opacity: opacity,
                mask: mask, effects: effects,
                transitionRange: transitionRange, transitionType: transitionType,
                transitionWipeAngle: transitionWipeAngle,
                showSkinMask: showSkinMask,
                clipSourceStart: clipSourceStart, sourceRange: sourceRange,
                orderingStart: orderingStart, zOrder: zOrder,
                transformKeyframes: transformKeyframes)
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

    private struct TimelineInterval {
        let start: Double
        let end: Double

        var isValid: Bool {
            start.isFinite && end.isFinite && end > start
        }

        var cmTimeRange: CMTimeRange {
            CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600))
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

                let transform = clip.geometry.isIdentity
                    ? fitTransform(
                        naturalSize: media.naturalSize,
                        preferredTransform: media.preferredTransform,
                        into: renderSize)
                    : geometryTransform(
                        naturalSize: media.naturalSize,
                        preferredTransform: media.preferredTransform,
                        geometry: clip.geometry,
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
                            mediaID: clip.mediaID,
                            compTrackID: compTrack.trackID,
                            timeRange: CMTimeRange(start: segmentStart,
                                                   duration: remapSegment.outputDuration),
                            transform: transform,
                            opacity: clip.opacity,
                            mask: clip.geometry.mask,
                            effects: clip.effects,
                            transitionRange: piece.transitionRange,
                            transitionType: piece.overlap > .zero ? clip.transition?.type : nil,
                            transitionWipeAngle: piece.overlap > .zero ? clip.transition?.wipeAngle : nil,
                            showSkinMask: showSkinMask,
                            clipSourceStart: clip.sourceStart,
                            sourceRange: remapSegment.sourceRange,
                            orderingStart: piece.effectiveStart,
                            zOrder: 0,
                            transformKeyframes: clip.transformKeyframes))
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

        // Apply layout track scene transforms to video segments. When layout
        // clips are present (from Program Mode landing), the scene's layer
        // definitions override the per-clip transforms so preview/export
        // replay the live switch layout.
        let sourceIDToMediaID = Dictionary(
            project.mediaItems.compactMap { item -> (UUID, UUID)? in
                guard let sid = item.captureSourceID else { return nil }
                return (sid, item.id)
            },
            uniquingKeysWith: { first, _ in first })
        let activeLayoutClips = project.layoutTracks
            .filter { !$0.isMuted }
            .flatMap(\.clips)
        if !activeLayoutClips.isEmpty {
            projectTrackSegments = applyLayoutOverrides(
                segments: projectTrackSegments,
                layoutClips: activeLayoutClips,
                sourceIDToMediaID: sourceIDToMediaID,
                renderSize: renderSize)
        }

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
        let visualRanges = visualActivityRanges(
            captionTracks: captionTracks,
            overlays: project.overlays,
            callouts: project.callouts,
            keystrokeOverlays: project.keystrokeOverlayClips)
        let videoRanges = projectTrackSegments.flatMap { segments in
            segments.map(\.timeRange)
        }
        let fillerVisualRanges = visualFillerRanges(visualRanges: visualRanges, videoRanges: videoRanges)

        var fillerTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        if !fillerVisualRanges.isEmpty {
            // Generate at most `fillerChunkSeconds` of source media; longer
            // visual-only spans reuse the same chunk via repeated `insertTimeRange`s.
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
                // arbitrarily long visual-only gap.
                for range in fillerVisualRanges {
                    var insertAt = range.start
                    var remaining = range.duration
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
                }
                fillerTrackID = fillerCompTrack.trackID
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
            callouts: project.callouts,
            keystrokeOverlays: project.keystrokeOverlayClips,
            paddedBackground: project.paddedBackground,
            totalDuration: totalDuration,
            renderSize: renderSize,
            frameRate: project.frameRate,
            fillerTrackID: fillerTrackID,
            fillerVisualRanges: fillerVisualRanges,
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

    // MARK: - Layout track overrides

    /// Applies scene-based transforms from layout clips to video segments.
    /// Each layout clip's scene layers override the corresponding ISO track
    /// segments' transforms/opacity for the clip's time range.
    private static func applyLayoutOverrides(
        segments: [[VideoSegment]],
        layoutClips: [LayoutClip],
        sourceIDToMediaID: [UUID: UUID],
        renderSize: CGSize
    ) -> [[VideoSegment]] {
        var result = segments

        for layoutClip in layoutClips {
            let clipStart = layoutClip.timelineStart.cmTime
            let clipEnd = layoutClip.timelineEnd.cmTime
            let clipRange = CMTimeRange(start: clipStart, end: clipEnd)
            guard clipRange.duration > .zero else { continue }

            let scene = layoutClip.sceneSnapshot
            let visibleLayers = scene.layers
                .filter { $0.visible }
                .sorted { $0.zIndex < $1.zIndex }

            // Build a per-layer transform/opacity/zOrder lookup by mediaID.
            // A26: Also track colour layers for composition insertion.
            var layerByMediaID: [UUID: (transform: CGAffineTransform, opacity: Float, zOrder: Int)] = [:]
            var colourLayers: [(hex: String, transform: CGAffineTransform, opacity: Float, zOrder: Int)] = []
            for layer in visibleLayers {
                switch layer.sourceRef {
                case .captureSource(let sourceID):
                    if let mediaID = sourceIDToMediaID[sourceID] {
                        let cgTransform = sceneLayerTransform(
                            layer: layer, canvasSize: renderSize)
                        layerByMediaID[mediaID] = (cgTransform, layer.opacity, layer.zIndex)
                    }
                case .colour(let hex):
                    let cgTransform = sceneLayerTransform(
                        layer: layer, canvasSize: renderSize)
                    colourLayers.append((hex, cgTransform, layer.opacity, layer.zIndex))
                case .still:
                    break
                }
            }

            // Override segments that overlap this layout clip.
            for trackIndex in result.indices {
                var newSegments: [VideoSegment] = []
                for seg in result[trackIndex] {
                    let segRange = seg.timeRange
                    // No overlap — keep as-is.
                    guard segRange.end > clipStart && segRange.start < clipEnd else {
                        newSegments.append(seg)
                        continue
                    }

                    // Split the segment at layout clip boundaries.
                    let pieces = splitSegmentAtLayoutBoundaries(
                        seg: seg, clipRange: clipRange)

                    for piece in pieces {
                        let pieceRange = piece.timeRange
                        let overlapsLayout = pieceRange.end > clipStart
                            && pieceRange.start < clipEnd

                        if overlapsLayout, let override = layerByMediaID[seg.mediaID] {
                            // A30: Compose scene transform with the original
                            // fit transform so sources with different natural
                            // sizes still render at the correct scale.
                            let composedTransform = seg.transform.concatenating(override.transform)
                            newSegments.append(VideoSegment(
                                clipID: piece.clipID,
                                mediaID: piece.mediaID,
                                compTrackID: piece.compTrackID,
                                timeRange: piece.timeRange,
                                transform: composedTransform,
                                opacity: seg.opacity * override.opacity,
                                mask: piece.mask,
                                effects: piece.effects,
                                transitionRange: piece.transitionRange,
                                transitionType: piece.transitionType,
                                transitionWipeAngle: piece.transitionWipeAngle,
                                showSkinMask: piece.showSkinMask,
                                clipSourceStart: piece.clipSourceStart,
                                sourceRange: piece.sourceRange,
                                orderingStart: piece.orderingStart,
                                zOrder: override.zOrder,
                                transformKeyframes: piece.transformKeyframes))
                        } else if overlapsLayout {
                            // A24: Source not in the active scene — suppress it.
                            newSegments.append(VideoSegment(
                                clipID: piece.clipID,
                                mediaID: piece.mediaID,
                                compTrackID: piece.compTrackID,
                                timeRange: piece.timeRange,
                                transform: piece.transform,
                                opacity: 0,
                                mask: piece.mask,
                                effects: piece.effects,
                                transitionRange: piece.transitionRange,
                                transitionType: piece.transitionType,
                                transitionWipeAngle: piece.transitionWipeAngle,
                                showSkinMask: piece.showSkinMask,
                                clipSourceStart: piece.clipSourceStart,
                                sourceRange: piece.sourceRange,
                                orderingStart: piece.orderingStart,
                                zOrder: 0,
                                transformKeyframes: piece.transformKeyframes))
                        } else {
                            newSegments.append(piece)
                        }
                    }
                }
                result[trackIndex] = newSegments
            }
        }
        return result
    }

    /// Converts a scene layer's normalised transform to canvas-pixel coordinates.
    private static func sceneLayerTransform(
        layer: SceneLayer, canvasSize: CGSize
    ) -> CGAffineTransform {
        let lt = layer.transform.cgTransform
        let canvasW = canvasSize.width
        let canvasH = canvasSize.height
        // Scale normalised ±0.5 translations to canvas pixels.
        let scaledLt = CGAffineTransform(
            a: lt.a, b: lt.b, c: lt.c, d: lt.d,
            tx: lt.tx * canvasW, ty: lt.ty * canvasH)
        let centreT = CGAffineTransform(translationX: canvasW / 2, y: canvasH / 2)
        let invCentreT = centreT.inverted()
        return invCentreT.concatenating(scaledLt).concatenating(centreT)
    }

    /// Splits a video segment at layout clip boundaries so each piece can
    /// have its own transform. Adjusts sourceRange proportionally so
    /// time-based effects/keyframes map correctly.
    private static func splitSegmentAtLayoutBoundaries(
        seg: VideoSegment, clipRange: CMTimeRange
    ) -> [VideoSegment] {
        let segStart = seg.timeRange.start
        let segEnd = seg.timeRange.end
        let segDuration = seg.timeRange.duration
        let clipStart = clipRange.start
        let clipEnd = clipRange.end

        func sourceRangeForPiece(_ pieceStart: CMTime, _ pieceEnd: CMTime) -> CMTimeRange {
            guard segDuration > .zero else { return seg.sourceRange }
            let startOffset = pieceStart - segStart
            let endOffset = pieceEnd - segStart
            let ratioStart = startOffset.seconds / segDuration.seconds
            let ratioEnd = endOffset.seconds / segDuration.seconds
            let srcDuration = seg.sourceRange.duration.seconds
            let srcStart = seg.sourceRange.start + CMTime(seconds: ratioStart * srcDuration, preferredTimescale: 600)
            let srcEnd = seg.sourceRange.start + CMTime(seconds: ratioEnd * srcDuration, preferredTimescale: 600)
            return CMTimeRange(start: srcStart, end: srcEnd)
        }

        var pieces: [VideoSegment] = []

        // Piece before the layout clip (if any).
        if segStart < clipStart {
            let end = CMTimeMinimum(segEnd, clipStart)
            let piece = seg.withTimeRange(CMTimeRange(start: segStart, end: end))
            pieces.append(VideoSegment(
                clipID: piece.clipID, mediaID: piece.mediaID, compTrackID: piece.compTrackID,
                timeRange: piece.timeRange, transform: piece.transform, opacity: piece.opacity,
                mask: piece.mask, effects: piece.effects,
                transitionRange: piece.transitionRange, transitionType: piece.transitionType,
                transitionWipeAngle: piece.transitionWipeAngle,
                showSkinMask: piece.showSkinMask,
                clipSourceStart: piece.clipSourceStart,
                sourceRange: sourceRangeForPiece(segStart, end),
                orderingStart: piece.orderingStart, zOrder: piece.zOrder,
                transformKeyframes: piece.transformKeyframes))
        }

        // Piece overlapping the layout clip.
        let overlapStart = CMTimeMaximum(segStart, clipStart)
        let overlapEnd = CMTimeMinimum(segEnd, clipEnd)
        if overlapEnd > overlapStart {
            let piece = seg.withTimeRange(CMTimeRange(start: overlapStart, end: overlapEnd))
            pieces.append(VideoSegment(
                clipID: piece.clipID, mediaID: piece.mediaID, compTrackID: piece.compTrackID,
                timeRange: piece.timeRange, transform: piece.transform, opacity: piece.opacity,
                mask: piece.mask, effects: piece.effects,
                transitionRange: piece.transitionRange, transitionType: piece.transitionType,
                transitionWipeAngle: piece.transitionWipeAngle,
                showSkinMask: piece.showSkinMask,
                clipSourceStart: piece.clipSourceStart,
                sourceRange: sourceRangeForPiece(overlapStart, overlapEnd),
                orderingStart: piece.orderingStart, zOrder: piece.zOrder,
                transformKeyframes: piece.transformKeyframes))
        }

        // Piece after the layout clip (if any).
        if segEnd > clipEnd {
            let start = CMTimeMaximum(segStart, clipEnd)
            let piece = seg.withTimeRange(CMTimeRange(start: start, end: segEnd))
            pieces.append(VideoSegment(
                clipID: piece.clipID, mediaID: piece.mediaID, compTrackID: piece.compTrackID,
                timeRange: piece.timeRange, transform: piece.transform, opacity: piece.opacity,
                mask: piece.mask, effects: piece.effects,
                transitionRange: piece.transitionRange, transitionType: piece.transitionType,
                transitionWipeAngle: piece.transitionWipeAngle,
                showSkinMask: piece.showSkinMask,
                clipSourceStart: piece.clipSourceStart,
                sourceRange: sourceRangeForPiece(start, segEnd),
                orderingStart: piece.orderingStart, zOrder: piece.zOrder,
                transformKeyframes: piece.transformKeyframes))
        }

        return pieces.isEmpty ? [seg] : pieces
    }

    private static func visualActivityRanges(captionTracks: [CaptionTrack],
                                             overlays: [OverlayClip],
                                             callouts: [CalloutClip] = [],
                                             keystrokeOverlays: [KeystrokeOverlayClip] = []) -> [CMTimeRange] {
        let captionRanges = captionTracks.flatMap { track in
            track.lines.map(\.range)
        }
        let overlayRanges = overlays.compactMap { overlay -> CMTimeRange? in
            guard overlay.timelineStart.isNumeric,
                  overlay.timelineEnd.isNumeric,
                  overlay.timelineEnd > overlay.timelineStart else { return nil }
            return CMTimeRange(start: overlay.timelineStart, end: overlay.timelineEnd)
        }
        let calloutRanges = callouts.compactMap { callout -> CMTimeRange? in
            let end = callout.timeRange.start + callout.timeRange.duration
            guard callout.timeRange.start.isNumeric, end.isNumeric, end > callout.timeRange.start else { return nil }
            return CMTimeRange(start: callout.timeRange.start, end: end)
        }
        let keystrokeRanges = keystrokeOverlays.compactMap { overlay -> CMTimeRange? in
            guard overlay.timeRange.start.isNumeric,
                  overlay.timeRange.end.isNumeric,
                  overlay.timeRange.end > overlay.timeRange.start else { return nil }
            return overlay.timeRange
        }
        return captionRanges + overlayRanges + calloutRanges + keystrokeRanges
    }

    private static func visualFillerRanges(visualRanges: [CMTimeRange],
                                           videoRanges: [CMTimeRange]) -> [CMTimeRange] {
        let visual = mergedIntervals(visualRanges)
        let video = mergedIntervals(videoRanges)
        guard !visual.isEmpty else { return [] }
        guard !video.isEmpty else { return visual.map(\.cmTimeRange) }

        var gaps: [TimelineInterval] = []
        for interval in visual {
            var cursor = interval.start
            for occupied in video where occupied.end > cursor && occupied.start < interval.end {
                if occupied.start > cursor {
                    gaps.append(TimelineInterval(start: cursor, end: min(occupied.start, interval.end)))
                }
                cursor = max(cursor, occupied.end)
                if cursor >= interval.end { break }
            }
            if cursor < interval.end {
                gaps.append(TimelineInterval(start: cursor, end: interval.end))
            }
        }
        return gaps.filter(\.isValid).map(\.cmTimeRange)
    }

    private static func mergedIntervals(_ ranges: [CMTimeRange]) -> [TimelineInterval] {
        let intervals = ranges.compactMap { range -> TimelineInterval? in
            guard range.start.isNumeric,
                  range.end.isNumeric else { return nil }
            let interval = TimelineInterval(start: range.start.seconds, end: range.end.seconds)
            return interval.isValid ? interval : nil
        }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }

        var merged: [TimelineInterval] = []
        for interval in intervals {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start <= last.end {
                merged[merged.count - 1] = TimelineInterval(
                    start: last.start,
                    end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
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

    static func geometryTransform(naturalSize: CGSize,
                                  preferredTransform: CGAffineTransform,
                                  geometry: ClipGeometry,
                                  into renderSize: CGSize) -> CGAffineTransform {
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { return preferredTransform }

        var transform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))
        transform = transform.concatenating(CGAffineTransform(scaleX: geometry.scale, y: geometry.scale))

        let scaledSize = CGSize(width: orientedSize.width * geometry.scale,
                                height: orientedSize.height * geometry.scale)
        let tx = (renderSize.width - scaledSize.width) / 2 + geometry.positionOffset.width
        let ty = (renderSize.height - scaledSize.height) / 2 - geometry.positionOffset.height
        return transform.concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// Builds non-overlapping custom instructions covering the timeline. For
    /// each interval between segment boundaries we emit one instruction whose
    /// render units describe what each project track shows — a single layer, or
    /// a transition blend of its two overlapping clips.
    private static func makeVideoComposition(
        composition: AVComposition,
        projectTrackSegments: [[VideoSegment]],
        captionTracks: [CaptionTrack],
        overlays: [OverlayClip],
        callouts: [CalloutClip] = [],
        keystrokeOverlays: [KeystrokeOverlayClip] = [],
        paddedBackground: PaddedBackgroundPreset? = nil,
        totalDuration: CMTime,
        renderSize: CGSize,
        frameRate: Double,
        fillerTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid,
        fillerVisualRanges: [CMTimeRange] = [],
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
            || !keystrokeOverlays.isEmpty
            || !callouts.isEmpty
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
        for callout in callouts {
            boundarySet.insert(callout.timeRange.start.seconds)
            let calloutEnd = callout.timeRange.start.seconds + callout.timeRange.duration.seconds
            boundarySet.insert(calloutEnd)
        }
        for overlay in keystrokeOverlays {
            boundarySet.insert(overlay.timeRange.start.seconds)
            boundarySet.insert(overlay.timeRange.end.seconds)
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

            // Visual-only intervals have no clip segment, but
            // the export pipeline still needs a `requiredSourceTrackIDs` entry
            // to schedule the compositor — surface the filler as a layer so
            // its track ID flows into the instruction. The layer renders as
            // black; captions and overlays composite on top.
            if units.isEmpty,
               fillerTrackID != kCMPersistentTrackID_Invalid,
               let fillerRange = fillerVisualRanges.first(where: {
                   $0.containsTime(CMTime(seconds: midpoint, preferredTimescale: 600))
               }) {
                units.append(.layer(CompositorLayer(
                    clipID: UUID(),  // filler; no real clip
                    trackID: fillerTrackID,
                    transform: .identity,
                    opacity: 1,
                    mask: .none,
                    effects: [],
                    showSkinMask: false,
                    clipSourceStart: fillerRange.start,
                    sourceRange: fillerRange,
                    timeRange: fillerRange,
                    transformKeyframes: Keyframed(defaultValue: .identity))))
            }

            let captionsForInterval = activeCaptionItems(
                in: captionTracks, midpoint: midpoint)
            let overlaysForInterval = activeOverlayItems(
                in: overlays, midpoint: midpoint)
            let keystrokeOverlaysForInterval = activeKeystrokeOverlayItems(
                in: keystrokeOverlays, midpoint: midpoint)
            let calloutsForInterval = callouts.filter { callout in
                let start = callout.timeRange.start.seconds
                let end = start + callout.timeRange.duration.seconds
                return start <= midpoint && midpoint < end
            }
            instructions.append(EffectCompositionInstruction(
                timeRange: range, units: units, captions: captionsForInterval,
                overlays: overlaysForInterval,
                overlaySourceRegistryID: overlaySourceRegistryID,
                keystrokeOverlays: keystrokeOverlaysForInterval,
                callouts: calloutsForInterval,
                paddedBackground: paddedBackground,
                paddedInsetMargin: paddedBackground?.insetMargin ?? 0,
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

    /// Keystroke overlay clips active at `midpoint`, ordered bottom-to-top
    /// matching the project's keystroke overlay array order.
    private static func activeKeystrokeOverlayItems(in overlays: [KeystrokeOverlayClip],
                                                    midpoint: Double) -> [KeystrokeOverlayRenderItem] {
        var items: [KeystrokeOverlayRenderItem] = []
        for overlay in overlays {
            let start = overlay.timeRange.start.seconds
            let end = overlay.timeRange.end.seconds
            guard start <= midpoint, midpoint < end else { continue }
            items.append(KeystrokeOverlayRenderItem(
                overlayID: overlay.id,
                range: overlay.timeRange,
                events: overlay.events,
                style: overlay.style,
                opacity: overlay.opacity))
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
