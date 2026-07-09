import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
@preconcurrency import CoreVideo
import os
import LocalCutCore

/// Decodes frames from a video file with an alpha channel using AVFoundation.
/// The alpha channel is preserved in the CIImage for correct compositing.
///
/// Uses the modern `AVAssetImageGenerator.image(at:)` async API for
/// frame-accurate random access without deprecation warnings.
nonisolated final class AlphaVideoSource: OverlayFrameSource, @unchecked Sendable {
    nonisolated let naturalSize: CGSize
    private let url: URL
    private let generator: AVAssetImageGenerator
    private let frameStarts: [TimeInterval]
    private let duration: TimeInterval

    /// CIImage is Sendable in macOS 26+ SDK; the lock provides thread safety.
    private struct CacheState: Sendable {
        var cache: [Int: CIImage] = [:]
        var cacheOrder: [Int] = []
    }
    private let cacheState = OSAllocatedUnfairLock(initialState: CacheState())
    /// Maximum cached frames retained for smooth short overlay playback.
    private let maxCachedFrames = 4

    private init(naturalSize: CGSize,
                 url: URL,
                 asset: AVAsset,
                 frameStarts: [TimeInterval],
                 duration: TimeInterval) {
        self.naturalSize = naturalSize
        self.url = url
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
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

        // Index frame timestamps using AVAssetReader.
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

        return AlphaVideoSource(
            naturalSize: displaySize,
            url: url,
            asset: asset,
            frameStarts: normalizedStarts,
            duration: duration.seconds)
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) async -> CIImage? {
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
        return await cachedFrame(at: index)
    }

    private func cachedFrame(at index: Int) async -> CIImage? {
        // Check cache first.
        if let cached = cacheState.withLock({ state -> CIImage? in
            guard let cached = state.cache[index] else { return nil }
            touchCachedFrame(at: index, in: &state)
            return cached
        }) {
            return cached
        }

        let requested = CMTime(seconds: frameStarts[index], preferredTimescale: 600)

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let result = try? await generator.image(at: requested) else {
            return nil
        }
        let image = CIImage(cgImage: result.image)

        cacheState.withLock { state in
            state.cache[index] = image
            touchCachedFrame(at: index, in: &state)
            while state.cacheOrder.count > maxCachedFrames {
                let evicted = state.cacheOrder.removeFirst()
                state.cache.removeValue(forKey: evicted)
            }
        }

        return image
    }

    nonisolated var cachedFrameCount: Int {
        cacheState.withLock { $0.cache.count }
    }

    nonisolated func purgeCachedFrames() {
        cacheState.withLock { state in
            state.cache.removeAll()
            state.cacheOrder.removeAll()
        }
    }

    private func touchCachedFrame(at index: Int, in state: inout CacheState) {
        state.cacheOrder.removeAll { $0 == index }
        state.cacheOrder.append(index)
    }
}
