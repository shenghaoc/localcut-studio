import Foundation
import CoreImage
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import LocalCutCore

/// Decodes frames from animated image files (WebP, GIF, APNG) using ImageIO.
/// Frames are decoded on demand and cached in a sliding window to bound memory.
nonisolated final class AnimatedImageSource: OverlayFrameSource, @unchecked Sendable {
    nonisolated let naturalSize: CGSize
    private let url: URL
    private let frameCount: Int
    private let totalDuration: TimeInterval
    /// Per-frame durations extracted at init time.
    private let frameDurations: [TimeInterval]
    /// Cumulative start time for each frame.
    private let frameStarts: [TimeInterval]
    /// Sliding-window cache: index → CIImage. Protected by lock.
    private let lock = NSLock()
    private var cache: [Int: CIImage] = [:]
    private let maxCachedFrames = 8

    init?(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }

        // Extract frame durations.
        var durations: [TimeInterval] = []
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
            let gifProps = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let webpProps = props?[kCGImagePropertyWebPDictionary as String] as? [String: Any]
            let apngProps = props?[kCGImagePropertyPNGDictionary as String] as? [String: Any]
            let delay = gifProps?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                ?? gifProps?[kCGImagePropertyGIFDelayTime as String] as? Double
                ?? webpProps?[kCGImagePropertyWebPUnclampedDelayTime as String] as? Double
                ?? webpProps?[kCGImagePropertyWebPDelayTime as String] as? Double
                ?? apngProps?[kCGImagePropertyAPNGUnclampedDelayTime as String] as? Double
                ?? apngProps?[kCGImagePropertyAPNGDelayTime as String] as? Double
                ?? props?["UnclampedDelayTime"] as? Double
                ?? props?["DelayTime"] as? Double
                ?? 0.1
            durations.append(max(delay, 0.01))
        }

        // Natural size from the first frame.
        guard let firstProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = firstProps[kCGImagePropertyPixelWidth as String] as? Double,
              let h = firstProps[kCGImagePropertyPixelHeight as String] as? Double,
              w > 0, h > 0 else { return nil }

        self.url = url
        self.frameCount = count
        self.naturalSize = CGSize(width: w, height: h)
        self.frameDurations = durations
        self.totalDuration = durations.reduce(0, +)

        // Build cumulative starts.
        var starts: [TimeInterval] = [0]
        for i in 0..<(count - 1) {
            starts.append(starts[i] + durations[i])
        }
        self.frameStarts = starts
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) async -> CIImage? {
        let t = time.seconds
        guard t >= 0 else { return nil }

        let effectiveTime: TimeInterval
        switch endAction {
        case .hide:
            guard t < totalDuration else { return nil }
            effectiveTime = t
        case .freeze:
            // Clamp to the start of the last frame, matching LottieFrameSource's
            // `totalDuration - (1 / frameRate)` formula. Use the last frame's own
            // start time so the freeze lands exactly on the last frame boundary.
            let lastFrameStart = frameStarts.last ?? 0
            effectiveTime = min(t, lastFrameStart)
        case .loop:
            effectiveTime = totalDuration > 0 ? t.truncatingRemainder(dividingBy: totalDuration) : 0
        }

        // Binary search for the frame index.
        let index = frameStarts.lastIndex(where: { $0 <= effectiveTime }) ?? 0

        // Check cache first.
        if let cached = lock.withLock({ cache[index] }) {
            return cached
        }

        // Decode outside the lock so concurrent callers can decode different
        // frames in parallel. Use a fresh image source so concurrent decodes do
        // not share mutable ImageIO decoder state.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let decodeSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(decodeSource, index, nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)

        // Insert into cache under lock.
        lock.withLock {
            cache[index] = ciImage
            if cache.count > maxCachedFrames {
                // Evict frames farthest from the current index.
                let sorted = cache.keys.sorted { abs($0 - index) < abs($1 - index) }
                for key in sorted.dropFirst(maxCachedFrames) {
                    cache.removeValue(forKey: key)
                }
            }
        }

        return ciImage
    }

    nonisolated var cachedFrameCount: Int {
        lock.withLock { cache.count }
    }

    nonisolated func purgeCachedFrames() {
        lock.withLock { cache.removeAll() }
    }
}
