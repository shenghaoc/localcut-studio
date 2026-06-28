import Foundation
import AppKit
import CoreImage
import CoreMedia
import Lottie
import LocalCutCore

/// Renders a Lottie JSON file into deterministic CIImage frames for the overlay
/// compositor. Rasterisation happens up front on the main actor because
/// `LottieAnimationView` is AppKit-backed; render-time lookup is then lock-free.
nonisolated final class LottieFrameSource: OverlayFrameSource, @unchecked Sendable {
    nonisolated let naturalSize: CGSize

    private let frames: [CIImage]
    private let frameRate: Double
    private let totalDuration: TimeInterval

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
        guard let data = await loadAnimationData(url: url) else { return nil }
        let animation: LottieAnimation?
        if url.pathExtension.lowercased() == "lottie" {
            let file = try? await DotLottieFile.loadedFrom(
                data: data,
                filename: url.lastPathComponent,
                dispatchQueue: .dotLottie)
            animation = file?.animations.first?.animation
        } else {
            animation = try? LottieAnimation.from(data: data)
        }
        guard let animation else { return nil }
        return LottieFrameSource(animation: animation)
    }

    private static func loadAnimationData(url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }.value
    }

    @MainActor
    private init?(animation: LottieAnimation) {
        let width = max(1, animation.size.width)
        let height = max(1, animation.size.height)
        let size = CGSize(width: width, height: height)
        let frameRate = max(1, animation.framerate)
        let frameCount = max(1, Int(ceil(animation.endFrame - animation.startFrame)))

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

        var rendered: [CIImage] = []
        rendered.reserveCapacity(frameCount)
        for offset in 0..<frameCount {
            let frame = animation.startFrame + CGFloat(offset)
            let image = autoreleasepool {
                Self.renderFrame(view: view, frame: frame, size: size)
            }
            guard let image else { return nil }
            rendered.append(image)
        }

        self.naturalSize = size
        self.frames = rendered
        self.frameRate = frameRate
        self.totalDuration = max(animation.duration, Double(frameCount) / frameRate)
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) async -> CIImage? {
        guard !frames.isEmpty else { return nil }
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

        let index = min(frames.count - 1, max(0, Int(floor(effectiveTime * frameRate))))
        return frames[index]
    }

    static func unsupportedFeatureWarning(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data),
              containsAfterEffectsLayerEffects(json) else {
            return nil
        }
        return "layer effects detected; preview/export use Lottie's fallback renderer."
    }

    static func unsupportedFeatureWarningAsync(for url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return unsupportedFeatureWarning(for: url)
        }.value
    }

    @MainActor
    private static func renderFrame(view: LottieAnimationView,
                                    frame: CGFloat,
                                    size: CGSize) -> CIImage? {
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
