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
    private let asset: AVAsset
    private let duration: TimeInterval
    private let lock = NSLock()
    private var generator: AVAssetImageGenerator?
    private var lastRequestedTime: CMTime = .zero
    private var lastImage: CIImage?

    init?(url: URL) {
        let avAsset = AVAsset(url: url)
        // Synchronous duration read — acceptable for short overlay clips.
        let dur = avAsset.duration
        guard dur.isValid && dur.seconds > 0 else { return nil }

        guard let track = avAsset.tracks(withMediaType: .video).first else { return nil }
        let size = track.naturalSize
        guard size.width > 0, size.height > 0 else { return nil }

        self.asset = avAsset
        self.naturalSize = size
        self.duration = dur.seconds
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) -> CIImage? {
        let t = time.seconds
        guard t >= 0 else { return nil }

        let effectiveTime: CMTime
        switch endAction {
        case .hide:
            guard t < duration else { return nil }
            effectiveTime = time
        case .freeze:
            effectiveTime = min(time, asset.duration - CMTime(value: 1, timescale: 600))
        case .loop:
            let looped = duration > 0 ? t.truncatingRemainder(dividingBy: duration) : 0
            effectiveTime = CMTime(seconds: looped, preferredTimescale: 600)
        }

        // Simple single-frame cache — overlays typically play sequentially.
        lock.lock()
        if let last = lastImage, lastRequestedTime == effectiveTime {
            lock.unlock()
            return last
        }
        lock.unlock()

        // Use AVAssetImageGenerator for frame-accurate seeking.
        let gen: AVAssetImageGenerator
        lock.lock()
        if let existing = generator {
            gen = existing
        } else {
            gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            generator = gen
        }
        lock.unlock()

        // Synchronous image generation — acceptable for short overlay clips
        // where latency is bounded. For production, consider an async
        // pre-decode buffer.
        guard let cgImage = try? gen.copyCGImage(at: effectiveTime, actualTime: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)

        lock.lock()
        lastRequestedTime = effectiveTime
        lastImage = ciImage
        lock.unlock()

        return ciImage
    }
}
