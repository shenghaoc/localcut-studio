import Foundation
import AVFoundation
import CoreGraphics

/// The product of building a project: an immutable composition plus the video
/// composition that describes how its video layers are transformed and stacked.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
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
        let compTrackID: CMPersistentTrackID
        let timeRange: CMTimeRange
        let transform: CGAffineTransform
        let opacity: Float
        let effects: [Effect]
        let transitionRange: CMTimeRange?
        let transitionType: TransitionType?

        var layer: CompositorLayer {
            CompositorLayer(trackID: compTrackID, transform: transform, opacity: opacity, effects: effects)
        }

        func contains(_ seconds: Double) -> Bool {
            timeRange.start.seconds <= seconds && seconds < timeRange.end.seconds
        }
    }

    static func build(project: Project) async throws -> BuiltComposition? {
        let composition = AVMutableComposition()
        let renderSize = project.renderSize

        // Project-wide transition cuts ripple every track so linked A/V stays
        // in sync; the rendered timeline shortens by the total overlap.
        let cuts = TransitionLayout.cuts(videoTracks: project.videoTracks)

        // Each project video track expands to two alternating composition tracks
        // (A/B-roll) so a transition's two clips can overlap on screen.
        // `projectTrackSegments` preserves bottom-to-top order.
        var projectTrackSegments: [[VideoSegment]] = []

        for projectTrack in project.videoTracks {
            guard let compTrackA = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compTrackB = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let pool = [compTrackA, compTrackB]

            var segments: [VideoSegment] = []
            let placements = TransitionLayout.placements(for: projectTrack.clips, cuts: cuts)
            for (index, placement) in placements.enumerated() {
                let clip = placement.clip
                guard let media = project.media(for: clip.mediaID), media.hasVideo else { continue }
                let sourceTracks = try await media.asset.loadTracks(withMediaType: .video)
                guard let sourceTrack = sourceTracks.first else { continue }

                let compTrack = pool[index % 2]
                try compTrack.insertTimeRange(clip.timeRangeInSource, of: sourceTrack, at: placement.effectiveStart)

                let transform = fitTransform(
                    naturalSize: media.naturalSize,
                    preferredTransform: media.preferredTransform,
                    into: renderSize)
                segments.append(VideoSegment(
                    compTrackID: compTrack.trackID,
                    timeRange: CMTimeRange(start: placement.effectiveStart, duration: clip.duration),
                    transform: transform,
                    opacity: clip.opacity,
                    effects: clip.effects,
                    transitionRange: placement.transitionRange,
                    transitionType: placement.clip.transition?.type))
            }
            projectTrackSegments.append(segments)
        }

        for projectTrack in project.audioTracks where !projectTrack.isMuted {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            let placements = TransitionLayout.placements(for: projectTrack.clips, cuts: cuts)
            for placement in placements {
                let clip = placement.clip
                guard let media = project.media(for: clip.mediaID), media.hasAudio else { continue }
                let sourceTracks = try await media.asset.loadTracks(withMediaType: .audio)
                guard let sourceTrack = sourceTracks.first else { continue }
                try compTrack.insertTimeRange(clip.timeRangeInSource, of: sourceTrack, at: placement.effectiveStart)
            }
        }

        let totalDuration = composition.duration
        guard totalDuration > .zero else { return nil }

        let videoComposition = try await makeVideoComposition(
            composition: composition,
            projectTrackSegments: projectTrackSegments,
            totalDuration: totalDuration,
            renderSize: renderSize,
            frameRate: project.frameRate)

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
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
        totalDuration: CMTime,
        renderSize: CGSize,
        frameRate: Double) async throws -> AVVideoComposition? {

        let hasAnySegment = projectTrackSegments.contains { !$0.isEmpty }
        guard hasAnySegment else { return nil }

        // Collect and sort every distinct boundary time, including overlap edges.
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

                if let incoming = visible.first(where: {
                        $0.transitionRange.map { $0.start.seconds <= midpoint && midpoint < $0.end.seconds } ?? false
                    }),
                   let overlap = incoming.transitionRange,
                   let type = incoming.transitionType,
                   let outgoing = visible.first(where: { $0.compTrackID != incoming.compTrackID }) {
                    units.append(.transition(outgoing: outgoing.layer, incoming: incoming.layer,
                                             type: type, overlap: overlap))
                } else {
                    // No active transition: stack any visible clips bottom-to-top.
                    for seg in visible {
                        units.append(.layer(seg.layer))
                    }
                }
            }

            instructions.append(EffectCompositionInstruction(timeRange: range, units: units))
        }

        var config = try await AVVideoComposition.Configuration(for: composition)
        config.renderSize = renderSize
        config.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        config.customVideoCompositorClass = EffectCompositor.self
        config.instructions = instructions
        return AVVideoComposition(configuration: config)
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
