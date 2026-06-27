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
    private let frameStarts: [TimeInterval]
    private let duration: TimeInterval

    private init(naturalSize: CGSize,
                 frames: [CIImage],
                 frameStarts: [TimeInterval],
                 duration: TimeInterval) {
        self.naturalSize = naturalSize
        self.frames = frames
        self.frameStarts = frameStarts
        self.duration = duration
    }

    static func make(url: URL) async -> AlphaVideoSource? {
        await Task.detached(priority: .userInitiated) {
            await makeWithScopedAccess(url: url)
        }.value
    }

    private static func makeWithScopedAccess(url: URL) async -> AlphaVideoSource? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).sanitized,
              duration.isValid,
              duration.seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let size = (try? await track.load(.naturalSize).sanitized) ?? .zero
        guard size.width > 0, size.height > 0 else { return nil }
        let transform = (try? await track.load(.preferredTransform).sanitized) ?? .identity
        let orientedRect = CGRect(origin: .zero, size: size).applying(transform)
        let orientedSize = CGSize(width: abs(orientedRect.width),
                                  height: abs(orientedRect.height)).sanitized
        let displaySize = orientedSize == .zero ? size : orientedSize

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var frames: [CIImage] = []
        var frameStarts: [TimeInterval] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            autoreleasepool {
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).sanitized.seconds
                let image = orientedImage(CIImage(cvImageBuffer: imageBuffer), transform: transform)
                frames.append(image)
                frameStarts.append(timestamp)
            }
        }

        guard !frames.isEmpty,
              reader.status != .failed,
              reader.status != .cancelled else {
            return nil
        }
        let firstStart = frameStarts.first ?? 0
        let normalizedStarts = frameStarts.map { max(0, $0 - firstStart) }
        return AlphaVideoSource(
            naturalSize: displaySize,
            frames: frames,
            frameStarts: normalizedStarts,
            duration: duration.seconds)
    }

    private static func orientedImage(_ image: CIImage,
                                      transform: CGAffineTransform) -> CIImage {
        guard transform != .identity else { return image }
        let transformed = image.transformed(by: transform)
        let extent = transformed.extent
        guard extent.origin != .zero else { return transformed }
        return transformed.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x,
            y: -extent.origin.y))
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
            effectiveTime = min(t, duration)
        case .loop:
            effectiveTime = duration > 0
                ? t.truncatingRemainder(dividingBy: duration)
                : 0
        }

        let index = frameStarts.lastIndex(where: { $0 <= effectiveTime }) ?? 0
        return frames[index]
    }
}
