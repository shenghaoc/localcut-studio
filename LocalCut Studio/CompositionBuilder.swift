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

    /// One placed clip on a composition track, in timeline coordinates, with the
    /// transform/opacity/effects to apply while it is on screen.
    private struct VideoSegment {
        let timeRange: CMTimeRange
        let transform: CGAffineTransform
        let opacity: Float
        let effects: [Effect]
    }

    static func build(project: Project) async throws -> BuiltComposition? {
        let composition = AVMutableComposition()
        let renderSize = project.renderSize

        // Each project video track maps to one composition track so its clips
        // share a layer. `trackSegments` preserves bottom-to-top order.
        var trackSegments: [(track: AVCompositionTrack, segments: [VideoSegment])] = []

        for projectTrack in project.videoTracks {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            var segments: [VideoSegment] = []
            for clip in projectTrack.clips {
                guard let media = project.media(for: clip.mediaID), media.hasVideo else { continue }
                let sourceTracks = try await media.asset.loadTracks(withMediaType: .video)
                guard let sourceTrack = sourceTracks.first else { continue }

                try compTrack.insertTimeRange(clip.timeRangeInSource, of: sourceTrack, at: clip.timelineStart)

                let transform = fitTransform(
                    naturalSize: media.naturalSize,
                    preferredTransform: media.preferredTransform,
                    into: renderSize)
                segments.append(VideoSegment(
                    timeRange: CMTimeRange(start: clip.timelineStart, duration: clip.duration),
                    transform: transform,
                    opacity: clip.opacity,
                    effects: clip.effects))
            }
            trackSegments.append((compTrack, segments))
        }

        for projectTrack in project.audioTracks where !projectTrack.isMuted {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            for clip in projectTrack.clips {
                guard let media = project.media(for: clip.mediaID), media.hasAudio else { continue }
                let sourceTracks = try await media.asset.loadTracks(withMediaType: .audio)
                guard let sourceTrack = sourceTracks.first else { continue }
                try compTrack.insertTimeRange(clip.timeRangeInSource, of: sourceTrack, at: clip.timelineStart)
            }
        }

        let totalDuration = composition.duration
        guard totalDuration > .zero else { return nil }

        let videoComposition = try await makeVideoComposition(
            composition: composition,
            trackSegments: trackSegments,
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
    /// each gap between clip boundaries we emit one instruction whose layer
    /// metadata describes every track segment visible during that interval.
    private static func makeVideoComposition(
        composition: AVComposition,
        trackSegments: [(track: AVCompositionTrack, segments: [VideoSegment])],
        totalDuration: CMTime,
        renderSize: CGSize,
        frameRate: Double) async throws -> AVVideoComposition? {

        let hasAnySegment = trackSegments.contains { !$0.segments.isEmpty }
        guard hasAnySegment else { return nil }

        // Collect and sort every distinct boundary time.
        var boundarySet = Set<Double>([0, totalDuration.seconds])
        for entry in trackSegments {
            for seg in entry.segments {
                boundarySet.insert(seg.timeRange.start.seconds)
                boundarySet.insert(seg.timeRange.end.seconds)
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

            // Build layers bottom-to-top so the compositor composites in the correct order.
            var layers: [CompositorLayer] = []
            for entry in trackSegments {
                guard let seg = entry.segments.first(where: {
                    $0.timeRange.start.seconds <= midpoint && midpoint < $0.timeRange.end.seconds
                }) else { continue }

                layers.append(CompositorLayer(
                    trackID: entry.track.trackID,
                    transform: seg.transform,
                    opacity: seg.opacity,
                    effects: seg.effects))
            }

            instructions.append(EffectCompositionInstruction(timeRange: range, layers: layers))
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
