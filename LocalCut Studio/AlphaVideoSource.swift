import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import LocalCutCore

/// Decodes frames from a video file with an alpha channel using AVFoundation.
/// The alpha channel is preserved in the CIImage for correct compositing.
nonisolated final class AlphaVideoSource: OverlayFrameSource, @unchecked Sendable {
    nonisolated let naturalSize: CGSize
    private let frames: [CIImage]
    private let frameRate: Double
    private let duration: TimeInterval

    private init(naturalSize: CGSize,
                 frames: [CIImage],
                 frameRate: Double,
                 duration: TimeInterval) {
        self.naturalSize = naturalSize
        self.frames = frames
        self.frameRate = frameRate
        self.duration = duration
    }

    static func make(url: URL) async -> AlphaVideoSource? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).sanitized,
              duration.isValid,
              duration.seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let size = (try? await track.load(.naturalSize).sanitized) ?? .zero
        guard size.width > 0, size.height > 0 else { return nil }

        let nominal = (try? await track.load(.nominalFrameRate)) ?? 30
        let frameRate = Double(max(1, min(60, nominal)))
        let frameCount = max(1, Int(ceil(duration.seconds * frameRate)))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [CIImage] = []
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let seconds = Double(index) / frameRate
            let requested = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let result = try? await generator.image(at: requested) else { continue }
            frames.append(CIImage(cgImage: result.image))
        }

        guard !frames.isEmpty else { return nil }
        return AlphaVideoSource(
            naturalSize: size,
            frames: frames,
            frameRate: frameRate,
            duration: duration.seconds)
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) -> CIImage? {
        guard !frames.isEmpty else { return nil }
        let t = time.seconds
        guard t >= 0 else { return nil }

        let effectiveTime: TimeInterval
        switch endAction {
        case .hide:
            guard t < duration else { return nil }
            effectiveTime = t
        case .freeze:
            effectiveTime = min(t, max(0, duration - (1 / frameRate)))
        case .loop:
            effectiveTime = duration > 0
                ? t.truncatingRemainder(dividingBy: duration)
                : 0
        }

        let index = min(frames.count - 1, max(0, Int(floor(effectiveTime * frameRate))))
        return frames[index]
    }
}
