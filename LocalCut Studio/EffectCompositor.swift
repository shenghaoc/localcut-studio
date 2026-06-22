import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreVideo
import os

// MARK: - Layer metadata for the compositor

struct CompositorLayer {
    /// Originating clip; used as part of the `RenderCache` key so the cached
    /// post-effect-chain image is invalidated when the clip's effects mutate.
    let clipID: UUID
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let opacity: Float
    let effects: [Effect]
    let showSkinMask: Bool
    /// The clip's start time on the timeline, used to compute clip-local time for keyframe evaluation.
    let clipStartTime: CMTime
    /// The piece's range within the source media, used to compute source time
    /// for the render cache key so repeated source frames hit the same entry.
    let sourceRange: CMTimeRange
    /// The piece's range on the composition timeline, paired with `sourceRange`
    /// to map composition time → source time.
    let timeRange: CMTimeRange
}

/// One caption line scheduled inside a composition instruction. Carries everything
/// the compositor needs to draw it on a frame without touching the runtime model.
struct CaptionRenderItem: Sendable {
    let lineID: UUID
    let text: String
    let words: [WordTiming]?
    let style: CaptionStyle
    let range: CMTimeRange
}

/// One bottom-to-top render step within an instruction interval: either a single
/// layer, or a transition that blends an outgoing and incoming layer over a
/// derived progress through the overlap interval.
enum RenderUnit {
    case layer(CompositorLayer)
    case transition(outgoing: CompositorLayer, incoming: CompositorLayer,
                    type: TransitionType, overlap: CMTimeRange)

    /// Every source track this unit reads from.
    nonisolated var trackIDs: [CMPersistentTrackID] {
        switch self {
        case .layer(let layer): [layer.trackID]
        case .transition(let outgoing, let incoming, _, _): [outgoing.trackID, incoming.trackID]
        }
    }
}

// MARK: - Custom instruction

final class EffectCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let units: [RenderUnit]
    let captions: [CaptionRenderItem]

    init(timeRange: CMTimeRange, units: [RenderUnit], captions: [CaptionRenderItem] = []) {
        self.timeRange = timeRange
        self.units = units
        self.captions = captions
        // A transition tweens its layers across the interval. Captions also tween
        // (per-frame animation transform), so any caption forces tweening too.
        containsTweening = !captions.isEmpty || units.contains {
            if case .transition = $0 { return true }; return false
        }
        let trackIDs = units.flatMap(\.trackIDs)
        requiredSourceTrackIDs = trackIDs.isEmpty ? [] : trackIDs.map { NSNumber(value: $0) as NSValue }
    }
}

// MARK: - Custom video compositor

final class EffectCompositor: NSObject, AVVideoCompositing {

    private static let sRGBColorSpace: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }()

    private static let sharedCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: sRGBColorSpace])
        }
        return CIContext(options: [.workingColorSpace: sRGBColorSpace])
    }()

    /// Shared rasteriser so the cache survives across composition rebuilds and
    /// frame requests. Internally thread-safe (uses `OSAllocatedUnfairLock`).
    private static let sharedCaptionRasterer = CaptionRasterer()

    nonisolated var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    }

    nonisolated var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    nonisolated func renderContextChanged(_: AVVideoCompositionRenderContext) {}

    nonisolated func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? EffectCompositionInstruction else {
            request.finish(with: AVError(.invalidVideoComposition))
            return
        }

        // Gate render-time collection on the diagnostics panel actually being
        // open — otherwise every preview / export frame would pay for a
        // timestamp + lock + ring-buffer mutation that nobody reads (Codex P2).
        let diagnosticsEnabled = DiagnosticsBridge.shared.isEnabled
        let renderStart: CFAbsoluteTime = diagnosticsEnabled ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if diagnosticsEnabled {
                DiagnosticsBridge.shared.recordRenderTime(CFAbsoluteTimeGetCurrent() - renderStart)
            }
        }

        let renderSize = request.renderContext.size
        var result: CIImage?

        for unit in instruction.units {
            guard let image = renderedImage(for: unit, request: request) else { continue }
            if let existing = result {
                result = image.composited(over: existing)
            } else {
                result = image
            }
        }

        // Captions sit on top of every clip layer, honouring track / instruction
        // order: earlier entries draw first, later entries on top.
        for item in instruction.captions {
            guard let layer = captionLayer(for: item, time: request.compositionTime,
                                           renderSize: renderSize) else { continue }
            result = layer.composited(over: result ?? CIImage(color: .clear)
                .cropped(to: CGRect(origin: .zero, size: renderSize)))
        }

        guard let destination = request.renderContext.newPixelBuffer() else {
            request.finish(with: AVError(.invalidVideoComposition))
            return
        }

        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))
        let composited = result?.composited(over: black) ?? black

        let destinationRect = CGRect(origin: .zero, size: renderSize)
        Self.sharedCIContext.render(composited, to: destination, bounds: destinationRect, colorSpace: Self.sRGBColorSpace)

        request.finish(withComposedVideoFrame: destination)
    }

    // MARK: - Render units

    /// Renders a single unit (a plain layer or a transition blend) to a CIImage.
    nonisolated private func renderedImage(
        for unit: RenderUnit,
        request: AVAsynchronousVideoCompositionRequest) -> CIImage? {

        switch unit {
        case .layer(let layer):
            return renderedImage(for: layer, request: request)

        case .transition(let outgoing, let incoming, let type, let overlap):
            let out = renderedImage(for: outgoing, request: request)
            let into = renderedImage(for: incoming, request: request)
            // If a source frame is missing, fall back to whichever is available.
            guard let out else { return into }
            guard let into else { return out }
            let progress = transitionProgress(time: request.compositionTime, overlap: overlap)
            switch type {
            case .crossDissolve:
                return crossDissolve(outgoing: out, incoming: into, progress: progress)
            case .wipe:
                return wipe(outgoing: out, incoming: into, progress: progress)
            }
        }
    }

    /// Applies the layer's effect chain, fit transform, and per-clip opacity to
    /// its source frame.
    nonisolated private func renderedImage(
        for layer: CompositorLayer,
        request: AVAsynchronousVideoCompositionRequest) -> CIImage? {

        guard let sourceBuffer = request.sourceFrame(byTrackID: layer.trackID) else { return nil }

        var image = CIImage(cvPixelBuffer: sourceBuffer)

        // Skin-smooth strength is keyframed in clip-local time.
        let clipLocalTime = request.compositionTime - layer.clipStartTime

        if layer.showSkinMask,
           let skinSmooth = layer.effects.first(where: {
               if case .skinSmooth = $0 { return true }; return false
           }),
           case .skinSmooth(let params) = skinSmooth {
            // Debug visualisation: show the skin-tone mask in place of the
            // smoothed frame. Bypass the cache so a normal preview after a
            // mask-toggle isn't served the mask image.
            if let mask = skinMask(image: image,
                                   warmthBias: params.maskWarmthBias,
                                   luminanceGate: params.maskLuminanceGate) {
                image = mask
            }
        } else {
            // Map composition time → source time so the cache key is stable
            // across repeated source-frame requests (speed ramps, frame
            // interpolation) and unique per source frame (no collisions
            // across pieces of the same clip).
            let cacheKey: RenderCacheKey? = layer.effects.isEmpty ? nil : {
                let rel = (request.compositionTime - layer.timeRange.start).seconds
                let tDur = layer.timeRange.duration.seconds
                let sDur = layer.sourceRange.duration.seconds
                let srcSec = layer.sourceRange.start.seconds + (tDur > 0 ? rel * sDur / tDur : 0)
                let sourceTime = CMTime(seconds: srcSec, preferredTimescale: RenderCacheKey.normalisedTimescale)
                return RenderCacheKey(
                    clipID: layer.clipID,
                    effectChainHash: layer.effects.renderCacheHash,
                    time: sourceTime,
                    renderSize: request.renderContext.size)
            }()
            image = applyEffectChain(image, effects: layer.effects,
                                     cacheKey: cacheKey, at: clipLocalTime)
        }

        image = image.transformed(by: layer.transform)

        if layer.opacity < 1 {
            // Scale alpha only (straight, not premultiplied): the later
            // source-over composite applies this alpha, so dimming RGB here too
            // would double-darken the clip.
            let opacityFilter = CIFilter.colorMatrix()
            opacityFilter.inputImage = image
            opacityFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity))
            image = opacityFilter.outputImage ?? image
        }

        // Normalise to the render canvas (transparent letterbox) so transition
        // filters and blends see matching extents even across clips of different
        // aspect ratios or orientations.
        let renderRect = CGRect(origin: .zero, size: request.renderContext.size)
        let canvas = CIImage(color: .clear).cropped(to: renderRect)
        return image.composited(over: canvas).cropped(to: renderRect)
    }

    // MARK: - Captions

    /// Renders one caption line for the current frame: looks up (or generates) the
    /// cached raster, evaluates the animation transforms, masks for typewriter,
    /// and scales alpha for opacity. Returns nil when the line draws nothing.
    nonisolated private func captionLayer(for item: CaptionRenderItem,
                                          time: CMTime,
                                          renderSize: CGSize) -> CIImage? {
        let wordIndex = activeWordIndex(for: item, at: time)
        let raster = wordIndex.map { index in
            Self.sharedCaptionRasterer.highlightRaster(
                line: makeLineProxy(item: item),
                style: item.style,
                renderSize: renderSize,
                wordIndex: index)
        } ?? Self.sharedCaptionRasterer.idleRaster(
            line: makeLineProxy(item: item),
            style: item.style,
            renderSize: renderSize)

        guard let raster, raster.boundingBox != .zero else { return nil }

        let animation = CaptionAnimation.evaluate(
            currentTime: time,
            lineStart: item.range.start,
            lineEnd: item.range.end,
            style: item.style)
        var image = raster.image

        if item.style.enterAnimation == .typewriter && animation.typewriterProgress < 1 {
            image = typewriterMasked(image: image,
                                     box: raster.boundingBox,
                                     progress: animation.typewriterProgress)
        }

        if animation.scale != 1 {
            let centre = CGPoint(x: raster.boundingBox.midX, y: raster.boundingBox.midY)
            var transform = CGAffineTransform.identity
                .translatedBy(x: centre.x, y: centre.y)
                .scaledBy(x: animation.scale, y: animation.scale)
                .translatedBy(x: -centre.x, y: -centre.y)
            transform = transform.translatedBy(x: animation.translation.width,
                                               y: animation.translation.height)
            image = image.transformed(by: transform)
        } else if animation.translation != .zero {
            image = image.transformed(by: CGAffineTransform(
                translationX: animation.translation.width,
                y: animation.translation.height))
        }

        if animation.opacity < 1 {
            let filter = CIFilter.colorMatrix()
            filter.inputImage = image
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(animation.opacity))
            image = filter.outputImage ?? image
        }

        return image.cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// CIImage gradient mask that reveals progressively from the left edge of the
    /// text bounding box across to the right, giving the typewriter effect
    /// without re-rasterising for each visible-length prefix. The mask is WHITE
    /// (not black) over the reveal area — `CIBlendWithMask` reads the mask as
    /// grayscale, so white = use input (visible) and clear = use background
    /// (hidden); an opaque-black mask would leave the caption invisible across
    /// the entire enter window.
    nonisolated private func typewriterMasked(image: CIImage, box: CGRect, progress: Float) -> CIImage {
        let progress = max(0, min(1, CGFloat(progress)))
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: box.minX,
                                y: box.minY,
                                width: box.width * progress,
                                height: box.height))
        let filter = CIFilter.blendWithMask()
        filter.inputImage = image
        filter.backgroundImage = CIImage(color: .clear).cropped(to: image.extent)
        filter.maskImage = mask
        return filter.outputImage ?? image
    }

    /// Reconstructs a minimal `CaptionLine` proxy for the rasterer cache key. The
    /// rasterer doesn't read the time range — only id, text, words — so the proxy
    /// can omit timing.
    nonisolated private func makeLineProxy(item: CaptionRenderItem) -> CaptionLine {
        CaptionLine(id: item.lineID, range: item.range, text: item.text,
                    words: item.words, style: item.style)
    }

    nonisolated private func activeWordIndex(for item: CaptionRenderItem, at time: CMTime) -> Int? {
        guard let words = item.words, !words.isEmpty else { return nil }
        for (i, word) in words.enumerated() where word.range.containsTime(time) {
            return i
        }
        return nil
    }

    // MARK: - Transitions

    /// Normalised progress (0...1) of `time` through the overlap interval.
    nonisolated private func transitionProgress(time: CMTime, overlap: CMTimeRange) -> Float {
        let duration = overlap.duration.seconds
        guard duration > 0 else { return 0 }
        let elapsed = (time - overlap.start).seconds
        return Float(max(0, min(1, elapsed / duration)))
    }

    /// A linear opacity-ramp cross-dissolve: `outgoing·(1-p) + incoming·p`.
    /// Implemented as premultiplied scaling plus additive compositing so the
    /// midpoint stays at full brightness (a true cross-fade).
    nonisolated private func crossDissolve(outgoing: CIImage, incoming: CIImage, progress: Float) -> CIImage {
        let fadedOut = scaled(outgoing, by: 1 - progress)
        let fadedIn = scaled(incoming, by: progress)
        let filter = CIFilter.additionCompositing()
        filter.inputImage = fadedIn
        filter.backgroundImage = fadedOut
        return filter.outputImage ?? fadedIn.composited(over: fadedOut)
    }

    /// A directional bars-swipe transition via Core Image. The type-safe builtin
    /// is created with the filter's default angle/width/bar-offset already set.
    nonisolated private func wipe(outgoing: CIImage, incoming: CIImage, progress: Float) -> CIImage {
        let filter = CIFilter.barsSwipeTransition()
        filter.inputImage = outgoing
        filter.targetImage = incoming
        filter.time = progress
        return filter.outputImage ?? crossDissolve(outgoing: outgoing, incoming: incoming, progress: progress)
    }

    /// Scales every (premultiplied) channel of an image by `factor` — a uniform
    /// opacity multiply.
    nonisolated private func scaled(_ image: CIImage, by factor: Float) -> CIImage {
        let f = CGFloat(factor)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: f, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: f, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: f, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: f)
        return filter.outputImage ?? image
    }

    // MARK: - Effect chain

    nonisolated private func applyEffectChain(_ image: CIImage,
                                              effects: [Effect],
                                              cacheKey: RenderCacheKey?,
                                              at time: CMTime = .zero) -> CIImage {
        if effects.isEmpty { return image }
        if let cacheKey, let cached = RenderCache.shared.image(for: cacheKey) {
            return cached
        }
        let sourceExtent = image.extent
        var result = image
        var allEffectsApplied = true
        for effect in effects {
            switch effect {
            case .colourGrade(let grade):
                result = applyColourGrade(result, grade: grade)
            case .lut(bookmark: let data):
                if let next = applyLUT(result, bookmarkData: data) {
                    result = next
                } else {
                    // Transient failure (file unreadable) — the `LUTCache`
                    // retry cool-down decides when to re-attempt. Caching the
                    // un-LUT'ed image now would freeze that for every later
                    // request at this key, defeating the retry path.
                    allEffectsApplied = false
                }
            case .skinSmooth(let params):
                // Returning nil here is deterministic (bypass, strength == 0,
                // kernel unavailable) — safe to cache as-is.
                result = applySkinSmooth(result, params: params, at: time) ?? result
            }
        }
        // Materialise into a CGImage-backed CIImage before caching: a lazy
        // CIImage filter graph would still force `CIContext.render` to
        // re-evaluate the colour / LUT / skin-smooth kernels on every hit, so
        // Phase 35 / 37's repeated-frame requests would still pay the work
        // this cache exists to avoid. Skip caching when an effect failed (see
        // above) and when the source extent is degenerate.
        guard let cacheKey, allEffectsApplied,
              !sourceExtent.isInfinite, !sourceExtent.isNull, !sourceExtent.isEmpty,
              let materialised = materialise(result, extent: sourceExtent) else {
            return result
        }
        RenderCache.shared.setImage(materialised, for: cacheKey)
        return materialised
    }

    /// Forces evaluation of `image` over `extent` by routing it through the
    /// shared `CIContext`. The returned CIImage is backed by a static CGImage,
    /// so a later `CIContext.render` only reuploads the texture instead of
    /// re-running the per-clip kernel chain.
    nonisolated private func materialise(_ image: CIImage, extent: CGRect) -> CIImage? {
        guard let cg = Self.sharedCIContext.createCGImage(image, from: extent) else {
            return nil
        }
        return CIImage(cgImage: cg)
    }

    nonisolated private func applyColourGrade(_ image: CIImage, grade: ColourGrade) -> CIImage {
        var result = image

        if grade.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = grade.exposure
            result = filter.outputImage ?? result
        }

        if grade.contrast != 1 || grade.saturation != 1 {
            let filter = CIFilter.colorControls()
            filter.inputImage = result
            filter.contrast = grade.contrast
            filter.saturation = grade.saturation
            result = filter.outputImage ?? result
        }

        if grade.temperatureOffset != 0 || grade.tintOffset != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 + CGFloat(grade.temperatureOffset), y: CGFloat(grade.tintOffset))
            result = filter.outputImage ?? result
        }

        return result
    }

    // MARK: - Skin smoothing kernels

    /// Skin-tone probability mask kernel — compiled once, reused across all frames.
    private static let skinMaskKernel: CIColorKernel? = {
        CIColorKernel(source: """
            kernel vec4 skinMask(__sample image, float warmthBias, float luminanceGate) {
                // Unpremultiply to get true colors for YCbCr conversion
                float alpha = image.a;
                vec3 rgb = alpha > 0.0 ? image.rgb / alpha : vec3(0.0);

                // YCbCr conversion (normalized 0-1 inputs, 0-1 outputs)
                float y = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b;
                float cb = 0.5 - 0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b;
                float cr = 0.5 + 0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b;

                // Skin tone detection in Cb-Cr space
                // Typical skin: Cb in [0.3, 0.5], Cr in [0.5, 0.7]
                float cbMin = 0.3 + warmthBias * 0.05;
                float cbMax = 0.5 + warmthBias * 0.05;
                float crMin = 0.5 + warmthBias * 0.05;
                float crMax = 0.7 + warmthBias * 0.05;

                // Soft falloff at edges
                float cbDist = smoothstep(cbMin - 0.05, cbMin, cb) * (1.0 - smoothstep(cbMax, cbMax + 0.05, cb));
                float crDist = smoothstep(crMin - 0.05, crMin, cr) * (1.0 - smoothstep(crMax, crMax + 0.05, cr));

                float skinProb = cbDist * crDist;

                // Luminance gate: reduce probability in very dark or very bright regions
                float lumGate = smoothstep(0.0, luminanceGate * 0.5, y) * (1.0 - smoothstep(1.0 - luminanceGate * 0.5, 1.0, y));
                skinProb *= lumGate;

                // Scale by alpha to prevent transparent regions from accumulating skin probability
                skinProb *= alpha;

                return vec4(skinProb, skinProb, skinProb, alpha);
            }
            """)
    }()

    /// Blend kernel for compositing smoothed image over original using mask — compiled once.
    private static let skinBlendKernel: CIColorKernel? = {
        CIColorKernel(source: """
            kernel vec4 skinBlend(__sample original, __sample smoothed, __sample mask, float strength) {
                float maskVal = mask.r * strength;
                return mix(original, smoothed, maskVal);
            }
            """)
    }()

    // MARK: - Skin smoothing

    /// Applies skin smoothing using a chroma-based skin-tone mask and masked Gaussian blur proxy.
    nonisolated private func applySkinSmooth(_ image: CIImage, params: SkinSmoothEffect, at time: CMTime) -> CIImage? {
        guard !params.bypass else { return nil }

        let strength = params.strength.value(at: time)
        guard strength > 0 else { return nil }

        // Step 1: Generate skin-tone probability mask
        guard let mask = skinMask(image: image, warmthBias: params.maskWarmthBias, luminanceGate: params.maskLuminanceGate) else {
            return nil
        }

        // Step 2: Apply masked Gaussian blur smoothing
        guard let smoothed = maskedGaussianBlurSmooth(image: image, mask: mask, strength: strength) else {
            return nil
        }

        return smoothed
    }

    /// Generates a single-channel skin-tone probability mask in [0,1].
    nonisolated private func skinMask(image: CIImage, warmthBias: Float, luminanceGate: Float) -> CIImage? {
        guard let kernel = Self.skinMaskKernel else { return nil }
        let bias = CGFloat(warmthBias)
        let gate = CGFloat(luminanceGate)
        return kernel.apply(extent: image.extent, arguments: [image, bias, gate])
    }

    /// Applies the masked Gaussian blur proxy to the selected skin region.
    ///
    /// Uses a two-pass approach:
    /// 1. Blur the image with clamped extent to prevent frame-edge bleeding
    /// 2. Blend original and smoothed based on mask and strength
    nonisolated private func maskedGaussianBlurSmooth(image: CIImage, mask: CIImage, strength: Float) -> CIImage? {
        // Clamp to extent before blurring to prevent transparent edge bleeding
        let clamped = image.clampedToExtent()

        // Apply a moderate blur — radius scales with strength
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = clamped
        blurFilter.radius = strength * 10.0
        guard let blurred = blurFilter.outputImage else { return nil }

        // Clip blurred image back to original extent
        let clippedBlurred = blurred.cropped(to: image.extent)

        // Blend using the pre-compiled kernel
        guard let kernel = Self.skinBlendKernel else { return nil }
        return kernel.apply(extent: image.extent, arguments: [image, clippedBlurred, mask, CGFloat(strength)])
    }

    // MARK: - LUT
    nonisolated private static let lutRetryInterval: TimeInterval = 3

    nonisolated private func applyLUT(_ image: CIImage, bookmarkData: Data) -> CIImage? {
        let prior = LUTCache.shared.entry(forBookmark: bookmarkData)
        switch prior {
        case .loaded(let cached):
            return colorCube(image: image, dimension: cached.dimension, cubeData: cached.cubeData)
        case .failed(let when):
            // Retry transient failures after a cooldown; otherwise skip silently so
            // a broken LUT doesn't re-resolve or re-log on every rendered frame.
            guard Date().timeIntervalSince(when) >= Self.lutRetryInterval else { return nil }
        case nil:
            break
        }

        guard let cached = loadLUT(bookmarkData: bookmarkData) else {
            // Log only on the first failure for this bookmark (prior == nil); a retry
            // (prior == .failed) stays silent, and a healthy .loaded never reaches here.
            if case nil = prior {
                os_log(.error, "LUT bookmark unreadable — skipping LUT effect (will retry)")
            }
            LUTCache.shared.setEntry(.failed(Date()), forBookmark: bookmarkData)
            return nil
        }
        LUTCache.shared.setEntry(.loaded(cached), forBookmark: bookmarkData)
        return colorCube(image: image, dimension: cached.dimension, cubeData: cached.cubeData)
    }

    /// Resolves and parses a LUT bookmark once. Returns nil when the file can't be
    /// reached, read, or parsed; the caller caches the outcome (with a retry
    /// cooldown) so this isn't repeated on every rendered frame.
    nonisolated private func loadLUT(bookmarkData: Data) -> CachedLUT? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                 options: [.withSecurityScope, .withoutUI],
                                 bookmarkDataIsStale: &isStale),
              !isStale else {
            return nil
        }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let lutData = try? Data(contentsOf: url),
              let result = CubeLUTParser.parse(lutData) else { return nil }

        let floats = result.table
        let cubeData = Data(bytes: floats, count: floats.count * MemoryLayout<Float>.stride)
        return CachedLUT(dimension: result.dimension, cubeData: cubeData)
    }

    nonisolated private func colorCube(image: CIImage, dimension: Int, cubeData: Data) -> CIImage? {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(dimension)
        filter.cubeData = cubeData
        filter.colorSpace = Self.sRGBColorSpace
        return filter.outputImage
    }
}

// MARK: - LUT cache

private struct CachedLUT: Sendable {
    let dimension: Int
    let cubeData: Data
}

/// Cached outcome of loading a LUT bookmark, so a broken LUT is neither
/// re-resolved nor re-logged on every rendered frame.
private enum LUTEntry: Sendable {
    case loaded(CachedLUT)
    case failed(Date)
}

private final class LUTCache: Sendable {
    nonisolated static let shared = LUTCache()
    private let lock = OSAllocatedUnfairLock(initialState: [Data: LUTEntry]())

    nonisolated func entry(forBookmark bookmark: Data) -> LUTEntry? {
        lock.withLock { $0[bookmark] }
    }

    nonisolated func setEntry(_ entry: LUTEntry, forBookmark bookmark: Data) {
        lock.withLock { $0[bookmark] = entry }
    }
}

// MARK: - .cube LUT parser

private struct CubeLUTResult {
    let dimension: Int
    let table: [Float]
}

private enum CubeLUTParser {

    /// Largest cube size accepted (matches common .cube exports). Bounds both the
    /// final table allocation and the pre-validation parse work below.
    nonisolated private static let maxDimension = 64

    nonisolated static func parse(_ data: Data) -> CubeLUTResult? {
        // Reject oversized input before any work: a 64³ cube is well under ~10 MB,
        // so a larger file can only be padding or an attempt to exhaust memory via
        // the String / line-array / entries allocations below.
        guard data.count <= 16 * 1024 * 1024,
              let content = String(data: data, encoding: .utf8) else { return nil }

        let maxEntries = maxDimension * maxDimension * maxDimension
        var dimension = 0
        var entries: [[Float]] = []

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("TITLE") { continue }

            let parts = trimmed.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !parts.isEmpty else { continue }

            if parts[0] == "LUT_3D_SIZE", parts.count >= 2 {
                // Bound the declared size: a crafted file could otherwise request a
                // huge cube (dimension³·4 floats) and exhaust memory.
                guard let size = Int(parts[1]), size > 1, size <= maxDimension else { return nil }
                dimension = size
                continue
            }

            guard let r = Float(parts[0]) else { continue }
            if parts.count >= 3, let g = Float(parts[1]), let b = Float(parts[2]) {
                entries.append([r, g, b])
                // Stop if the table outgrows the largest accepted cube, even when
                // LUT_3D_SIZE is missing or declared after the data lines.
                if entries.count > maxEntries { return nil }
            }
        }

        guard dimension > 1,
              entries.count == dimension * dimension * dimension else { return nil }

        var table = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        for i in 0..<entries.count {
            let entry = entries[i]
            table[i * 4 + 0] = entry[0]
            table[i * 4 + 1] = entry[1]
            table[i * 4 + 2] = entry[2]
            table[i * 4 + 3] = 1.0
        }

        return CubeLUTResult(dimension: dimension, table: table)
    }
}
