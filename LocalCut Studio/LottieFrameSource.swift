import Foundation
import AppKit
import CoreImage
import CoreMedia
import Lottie
import os
import LocalCutCore

/// Renders a Lottie JSON file into deterministic CIImage frames for the overlay
/// compositor. `LottieAnimationView` is AppKit-backed, so rasterisation happens
/// on the main actor, but frames are cached in a bounded window instead of
/// pre-rendering the full animation into memory.
nonisolated final class LottieFrameSource: OverlayFrameSource, @unchecked Sendable {
    nonisolated let naturalSize: CGSize

    private let renderer: LottieFrameRenderer
    private let frameRate: Double
    private let startFrame: CGFloat
    private let frameCount: Int
    private let totalDuration: TimeInterval

    /// @unchecked Sendable because CIImage is a reference type not
    /// annotated Sendable; the lock provides the necessary thread safety.
    private struct CacheState: @unchecked Sendable {
        var cache: [Int: CIImage] = [:]
        var cacheOrder: [Int] = []
    }
    private let cacheState = OSAllocatedUnfairLock(initialState: CacheState())
    private let maxCachedFrames: Int
    /// Maximum bytes used to drive per-frame cache eviction. At 1080p
    /// (8 MiB/frame) this holds ~8 frames; at 4K (33 MiB/frame) ~2.
    private static let maxCachedBytes = 64 * 1024 * 1024
    private static let maxRasterDimension: CGFloat = 8_192

    @MainActor
    convenience init?(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let animation = try? LottieAnimation.from(data: data) else {
            return nil
        }
        self.init(animation: animation)
    }

    @MainActor
    static func make(url: URL) async -> LottieFrameSource? {
        guard let animation = await loadAnimation(url: url) else { return nil }
        return LottieFrameSource(animation: animation)
    }

    private static func loadAnimation(url: URL) async -> LottieAnimation? {
        await Task.detached(priority: .userInitiated) { () async -> LottieAnimation? in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            if url.pathExtension.lowercased() == "lottie" {
                let file = try? await DotLottieFile.loadedFrom(
                    data: data,
                    filename: url.lastPathComponent,
                    dispatchQueue: .dotLottie)
                return file?.animations.first?.animation
            }
            return try? LottieAnimation.from(data: data)
        }.value
    }

    static func unsupportedFeatureWarning(for url: URL) -> String? {
        guard url.pathExtension.lowercased() != "lottie",
              let data = try? Data(contentsOf: url),
              containsAfterEffectsLayerEffects(in: data) else {
            return nil
        }
        return unsupportedFeatureWarningMessage
    }

    static func unsupportedFeatureWarningAsync(for url: URL) async -> String? {
        await Task.detached(priority: .utility) { () async -> String? in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            if url.pathExtension.lowercased() == "lottie" {
                let file = try? await DotLottieFile.loadedFrom(
                    data: data,
                    filename: url.lastPathComponent,
                    dispatchQueue: .dotLottie)
                guard file?.animations.contains(where: { containsAfterEffectsLayerEffects(in: $0.animation) }) == true else {
                    return nil
                }
                return unsupportedFeatureWarningMessage
            }
            guard containsAfterEffectsLayerEffects(in: data) else { return nil }
            return unsupportedFeatureWarningMessage
        }.value
    }

    private static let unsupportedFeatureWarningMessage =
        "layer effects detected; preview/export use Lottie's fallback renderer."

    private static func containsAfterEffectsLayerEffects(in data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return containsAfterEffectsLayerEffects(json)
    }

    private static func containsAfterEffectsLayerEffects(in animation: LottieAnimation) -> Bool {
        guard let data = try? JSONEncoder().encode(animation) else {
            return false
        }
        return containsAfterEffectsLayerEffects(in: data)
    }

    @MainActor
    private init?(animation: LottieAnimation) {
        guard animation.size.width.isFinite,
              animation.size.height.isFinite else {
            return nil
        }
        let width = max(1, animation.size.width)
        let height = max(1, animation.size.height)
        guard width <= Self.maxRasterDimension,
              height <= Self.maxRasterDimension else {
            return nil
        }
        let size = CGSize(width: width, height: height)
        let frameRate = max(1, animation.framerate)
        let frameCount = max(1, Int(ceil(animation.endFrame - animation.startFrame)))

        self.naturalSize = size
        self.renderer = LottieFrameRenderer(animation: animation, size: size)
        self.frameRate = frameRate
        self.startFrame = animation.startFrame
        self.frameCount = frameCount
        self.totalDuration = max(animation.duration, Double(frameCount) / frameRate)
        let widthPixels = max(1, Int(ceil(width)))
        let heightPixels = max(1, Int(ceil(height)))
        let bytesPerFrame = max(1, widthPixels * heightPixels * 4)
        self.maxCachedFrames = max(1, min(8, Self.maxCachedBytes / bytesPerFrame))
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) async -> CIImage? {
        guard frameCount > 0 else { return nil }
        let seconds = time.seconds
        guard seconds >= 0 else { return nil }

        let effectiveTime: TimeInterval
        switch endAction {
        case .hide:
            guard seconds < totalDuration else { return nil }
            effectiveTime = seconds
        case .freeze:
            effectiveTime = min(seconds, max(0, totalDuration - (1 / frameRate)))
        case .loop:
            effectiveTime = totalDuration > 0
                ? seconds.truncatingRemainder(dividingBy: totalDuration)
                : 0
        }

        let index = min(frameCount - 1, max(0, Int(floor(effectiveTime * frameRate))))
        if let cached = cacheState.withLock({ state -> CIImage? in
            guard let cached = state.cache[index] else { return nil }
            touchCachedFrame(at: index, in: &state)
            return cached
        }) {
            return cached
        }

        guard let image = await renderer.renderFrame(at: startFrame + CGFloat(index)) else {
            return nil
        }

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

    private static func containsAfterEffectsLayerEffects(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let effects = dictionary["ef"] as? [Any], !effects.isEmpty {
                return true
            }
            return dictionary.values.contains { containsAfterEffectsLayerEffects($0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsAfterEffectsLayerEffects($0) }
        }
        return false
    }
}

@MainActor
private final class LottieFrameRenderer {
    private let view: LottieAnimationView
    private let size: CGSize

    init(animation: LottieAnimation, size: CGSize) {
        let configuration = LottieConfiguration(
            renderingEngine: .mainThread,
            reducedMotionOption: .standardMotion)
        let view = LottieAnimationView(animation: animation, configuration: configuration)
        view.frame = CGRect(origin: .zero, size: size)
        view.bounds = CGRect(origin: .zero, size: size)
        view.contentMode = .scaleAspectFit
        view.wantsLayer = true
        view.layer?.contentsScale = 1
        view.layoutSubtreeIfNeeded()
        self.view = view
        self.size = size
    }

    func renderFrame(at frame: CGFloat) -> CIImage? {
        autoreleasepool {
            view.currentFrame = frame
            view.forceDisplayUpdate()
            view.displayIfNeeded()

            let bounds = CGRect(origin: .zero, size: size)
            if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
                rep.size = size
                view.cacheDisplay(in: bounds, to: rep)
                if let cgImage = rep.cgImage {
                    return CIImage(cgImage: cgImage)
                }
            }

            let width = max(1, Int(ceil(size.width)))
            let height = max(1, Int(ceil(size.height)))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let layer = view.layer else {
                return nil
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            layer.render(in: context)
            guard let cgImage = context.makeImage() else { return nil }
            return CIImage(cgImage: cgImage)
        }
    }
}
