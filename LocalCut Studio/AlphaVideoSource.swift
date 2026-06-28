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
    private let url: URL
    private let generator: AVAssetImageGenerator
    private let frameStarts: [TimeInterval]
    private let duration: TimeInterval
    private let lock = NSLock()
    private var cache: [Int: CIImage] = [:]
    private var cacheOrder: [Int] = []
    private let maxCachedFrames = 8

    private init(naturalSize: CGSize,
                 url: URL,
                 generator: AVAssetImageGenerator,
                 frameStarts: [TimeInterval],
                 duration: TimeInterval) {
        self.naturalSize = naturalSize
        self.url = url
        self.generator = generator
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
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var frameStarts: [TimeInterval] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            autoreleasepool {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).sanitized.seconds
                frameStarts.append(timestamp)
            }
        }

        guard !frameStarts.isEmpty,
              reader.status != .failed,
              reader.status != .cancelled else {
            return nil
        }
        let firstStart = frameStarts.first ?? 0
        let normalizedStarts = frameStarts.map { max(0, $0 - firstStart) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return AlphaVideoSource(
            naturalSize: displaySize,
            url: url,
            generator: generator,
            frameStarts: normalizedStarts,
            duration: duration.seconds)
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) -> CIImage? {
        guard !frameStarts.isEmpty else { return nil }
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
        return cachedFrame(at: index)
    }

    private func cachedFrame(at index: Int) -> CIImage? {
        lock.lock()
        if let cached = cache[index] {
            touchCachedFrame(at: index)
            lock.unlock()
            return cached
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            lock.unlock()
        }

        let requested = CMTime(seconds: frameStarts[index], preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: requested, actualTime: nil) else {
            return nil
        }
        let image = CIImage(cgImage: cgImage)
        cache[index] = image
        touchCachedFrame(at: index)
        while cacheOrder.count > maxCachedFrames {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return image
    }

    private func touchCachedFrame(at index: Int) {
        cacheOrder.removeAll { $0 == index }
        cacheOrder.append(index)
    }
}
