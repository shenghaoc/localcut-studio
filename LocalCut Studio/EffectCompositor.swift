import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreVideo
import os
import LocalCutCore

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
    /// The clip's source in-point, used to compute source-local time for keyframe evaluation.
    let clipSourceStart: CMTime
    /// The piece's range within the source media, used to compute source time
    /// for the render cache key so repeated source frames hit the same entry.
    let sourceRange: CMTimeRange
    /// The piece's range on the composition timeline, paired with `sourceRange`
    /// to map composition time → source time.
    let timeRange: CMTimeRange

    nonisolated func sourceTime(at compositionTime: CMTime) -> CMTime {
        let rel = CMTimeMaximum(.zero, compositionTime - timeRange.start)
        let tDur = timeRange.duration.seconds
        let sDur = sourceRange.duration.seconds
        let srcSec = sourceRange.start.seconds + (tDur > 0 ? rel.seconds * sDur / tDur : 0)
        return CMTime(seconds: srcSec, preferredTimescale: RenderCacheKey.normalisedTimescale)
    }
}

/// One caption line scheduled inside a composition instruction. Carries everything
/// the compositor needs to draw it on a frame without touching the runtime model.
struct CaptionRenderItem: Sendable {
    let lineID: UUID
    let text: String
    let words: [WordTiming]?
    let style: CaptionStyle
    let styleKeyframes: CaptionStyleKeyframes?
    let range: CMTimeRange
}

/// One bottom-to-top render step within an instruction interval: either a single
/// layer, or a transition that blends an outgoing and incoming layer over a
/// derived progress through the overlap interval.
enum RenderUnit {
    case layer(CompositorLayer)
    case transition(outgoing: CompositorLayer, incoming: CompositorLayer,
                    type: TransitionType, wipeAngle: Double, overlap: CMTimeRange)

    /// Every source track this unit reads from.
    nonisolated var trackIDs: [CMPersistentTrackID] {
        switch self {
        case .layer(let layer): [layer.trackID]
        case .transition(let outgoing, let incoming, _, _, _): [outgoing.trackID, incoming.trackID]
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
    /// Working colour space — drives the per-space `CIContext` choice and the
    /// output buffer's colour-tag attachments.
    let workingColourSpace: WorkingColourSpace

    init(timeRange: CMTimeRange, units: [RenderUnit], captions: [CaptionRenderItem] = [],
         workingColourSpace: WorkingColourSpace = .sRGB) {
        self.timeRange = timeRange
        self.units = units
        self.captions = captions
        self.workingColourSpace = workingColourSpace
        // Always report true so AVPlayer calls our custom compositor for every
        // frame. When containsTweening is false, AVFoundation may bypass the
        // custom compositor and fall back to default rendering, which does not
        // understand our EffectCompositionInstruction and produces no video.
        containsTweening = true
        let trackIDs = units.flatMap(\.trackIDs)
        requiredSourceTrackIDs = trackIDs.isEmpty ? [] : trackIDs.map { NSNumber(value: $0) as NSValue }
    }
}

// MARK: - Custom video compositor

final class EffectCompositor: NSObject, AVVideoCompositing {

    /// Per-working-space `CIContext` cache. `CIContext.workingColorSpace` is
    /// constructor-only, so we hold one context per space rather than juggle
    /// per-render conversions. The cache survives composition rebuilds.
    /// `uncheckedState:` because `CIContext` is not `Sendable`; the lock is
    /// the synchronisation, not the type system.
    private static let contextCache = OSAllocatedUnfairLock<[WorkingColourSpace: CIContext]>(uncheckedState: [:])

    nonisolated static func context(for space: WorkingColourSpace) -> CIContext {
        contextCache.withLock { cache in
            if let existing = cache[space] { return existing }
            let cs = space.cgColorSpace
            let ctx: CIContext
            if let device = MTLCreateSystemDefaultDevice() {
                ctx = CIContext(mtlDevice: device, options: [.workingColorSpace: cs])
            } else {
                ctx = CIContext(options: [.workingColorSpace: cs])
            }
            cache[space] = ctx
            return ctx
        }
    }

    /// Tags `buffer` with the colour primaries / transfer function / YCbCr
    /// matrix attachments matching `space`, so the export writer (which copies
    /// the destination buffer's attachments onto the encoded frame) writes a
    /// colour-tagged movie. `.shouldPropagate` keeps the tags attached when the
    /// buffer is copied internally by AVFoundation.
    nonisolated static func applyColourAttachments(_ space: WorkingColourSpace, to buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              space.cvColorPrimaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              space.cvTransferFunction, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              space.cvYCbCrMatrix, .shouldPropagate)
    }

    /// Shared rasteriser so the cache survives across composition rebuilds and
    /// frame requests. Internally thread-safe (uses `OSAllocatedUnfairLock`).
    private static let sharedCaptionRasterer = CaptionRasterer()

    /// Empties the shared caption-raster cache. Called when the project's
    /// working colour space changes — cached rasters were rendered in the
    /// previous space and must be re-rendered in the new one (R1.3).
    nonisolated static func purgeCaptionRasterCache() {
        sharedCaptionRasterer.purge()
    }

    /// Diagnostic accessor for tests covering R6.1.
    nonisolated static var captionRasterCacheCount: Int {
        sharedCaptionRasterer.count
    }

    /// Test-only seam: populate the shared raster cache for one line + style at
    /// the given render size. Returns whether an entry was inserted.
    @discardableResult
    nonisolated static func _testPopulateCaptionRasterCache(line: CaptionLine,
                                                            style: CaptionStyle,
                                                            renderSize: CGSize) -> Bool {
        let before = sharedCaptionRasterer.count
        _ = sharedCaptionRasterer.idleRaster(line: line, style: style, renderSize: renderSize)
        return sharedCaptionRasterer.count > before
    }

    nonisolated var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    }

    nonisolated var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    nonisolated func renderContextChanged(_: AVVideoCompositionRenderContext) {}

    nonisolated func cancelAllPendingVideoCompositionRequests() {}

    nonisolated func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? EffectCompositionInstruction else {
            request.finish(with: AVError(.invalidVideoComposition))
            return
        }

        // Gate render-time collection on the diagnostics panel actually being
        // open — otherwise every preview / export frame would pay for a
        // timestamp + lock + ring-buffer mutation that nobody reads (Codex P2).
        let diagnosticsEnabled = DiagnosticsBridge.shared.isEnabled
        let renderStart: TimeInterval = diagnosticsEnabled ? ProcessInfo.processInfo.systemUptime : 0
        defer {
            if diagnosticsEnabled {
                DiagnosticsBridge.shared.recordRenderTime(ProcessInfo.processInfo.systemUptime - renderStart)
            }
        }

        let renderSize = request.renderContext.size
        let space = instruction.workingColourSpace
        let ciContext = Self.context(for: space)
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
        let outputColorSpace = space.cgColorSpace
        ciContext.render(composited, to: destination, bounds: destinationRect, colorSpace: outputColorSpace)

        // Tag the output buffer so the export pipeline writes a colour-tagged
        // movie instead of silently flattening to sRGB (R2.2).
        Self.applyColourAttachments(space, to: destination)

        // Feed the scopes sampler on a 30 Hz cap; the sampler shortcuts to a
        // no-op when its panel is hidden, so this is free in the common case.
        if ScopeSampler.shared.shouldSample() {
            let sample = ScopeSampler.shared.sample(image: composited, context: ciContext,
                                                    colorSpace: outputColorSpace)
            ScopeSampler.shared.publish(sample)
        }

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

        case .transition(let outgoing, let incoming, let type, let wipeAngle, let overlap):
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
                return wipe(outgoing: out, incoming: into, progress: progress, angle: wipeAngle)
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

        // Per-clip effect keyframes are authored in source-local time so retimed
        // segments still evaluate the effect at the frame's real media timestamp.
        let sourceTime = layer.sourceTime(at: request.compositionTime)
        let clipLocalTime = sourceTime - layer.clipSourceStart

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
            image = scaled(image, by: layer.opacity)
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
        let localTime = CMTimeMaximum(time - item.range.start, .zero)
        let styleValues = item.styleKeyframes?.values(at: localTime)
        let rasterStyle = item.styleKeyframes?.rasterStyle(base: item.style, at: localTime)
            ?? item.style
        let wordIndex = activeWordIndex(for: item, at: time)
        let raster = wordIndex.map { index in
            Self.sharedCaptionRasterer.highlightRaster(
                line: makeLineProxy(item: item, style: rasterStyle),
                style: rasterStyle,
                renderSize: renderSize,
                wordIndex: index)
        } ?? Self.sharedCaptionRasterer.idleRaster(
            line: makeLineProxy(item: item, style: rasterStyle),
            style: rasterStyle,
            renderSize: renderSize)

        guard let raster, raster.boundingBox != .zero else { return nil }

        let animation = CaptionAnimation.evaluate(
            currentTime: time,
            lineStart: item.range.start,
            lineEnd: item.range.end,
            style: rasterStyle)
        var image = raster.image

        if rasterStyle.enterAnimation == .typewriter && animation.typewriterProgress < 1 {
            image = typewriterMasked(image: image,
                                     textBox: raster.textBox,
                                     progress: animation.typewriterProgress)
        }

        let keyedScale = CGFloat(styleValues?.scale ?? 1)
        let combinedScale = animation.scale * keyedScale
        let keyedTranslation = CGSize(width: CGFloat(styleValues?.offsetX ?? 0),
                                      height: CGFloat(styleValues?.offsetY ?? 0))
        let combinedTranslation = CGSize(
            width: animation.translation.width + keyedTranslation.width,
            height: animation.translation.height + keyedTranslation.height)
        if combinedScale != 1 {
            let centre = CGPoint(x: raster.boundingBox.midX, y: raster.boundingBox.midY)
            var transform = CGAffineTransform.identity
                .translatedBy(x: centre.x, y: centre.y)
                .scaledBy(x: combinedScale, y: combinedScale)
                .translatedBy(x: -centre.x, y: -centre.y)
            transform = transform.translatedBy(x: combinedTranslation.width,
                                               y: combinedTranslation.height)
            image = image.transformed(by: transform)
        } else if combinedTranslation != .zero {
            image = image.transformed(by: CGAffineTransform(
                translationX: combinedTranslation.width,
                y: combinedTranslation.height))
        }

        let combinedOpacity = CGFloat(animation.opacity) * CGFloat(styleValues?.opacity ?? 1)
        if combinedOpacity < 1 {
            image = scaled(image, by: Float(combinedOpacity))
        }

        return image.cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// CIImage mask that reveals progressively from the left edge of the text
    /// box while keeping the surrounding raster (notably the caption pill)
    /// visible. `CIBlendWithMask` reads white as input-visible and black as
    /// background-visible.
    nonisolated private func typewriterMasked(image: CIImage, textBox: CGRect, progress: Float) -> CIImage {
        let mask = Self.typewriterMask(imageExtent: image.extent, textBox: textBox, progress: progress)
        let filter = CIFilter.blendWithMask()
        filter.inputImage = image
        filter.backgroundImage = CIImage(color: .clear).cropped(to: image.extent)
        filter.maskImage = mask
        return filter.outputImage ?? image
    }

    nonisolated static func typewriterMask(imageExtent: CGRect, textBox: CGRect, progress: Float) -> CIImage {
        let progress = max(0, min(1, CGFloat(progress)))
        let visibleWidth = textBox.width * progress
        let hiddenText = CGRect(x: textBox.minX + visibleWidth,
                                y: textBox.minY,
                                width: textBox.width - visibleWidth,
                                height: textBox.height)
            .intersection(imageExtent)
        let visible = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: imageExtent)
        guard !hiddenText.isEmpty else { return visible }
        let hidden = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: hiddenText)
        return hidden.composited(over: visible)
    }

    /// Reconstructs a minimal `CaptionLine` proxy for the rasterer cache key. The
    /// rasterer doesn't read the time range — only id, text, words — so the proxy
    /// can omit timing.
    nonisolated private func makeLineProxy(item: CaptionRenderItem,
                                           style: CaptionStyle) -> CaptionLine {
        CaptionLine(id: item.lineID, range: item.range, text: item.text,
                    words: item.words, style: style,
                    styleKeyframes: item.styleKeyframes)
    }

    nonisolated private func activeWordIndex(for item: CaptionRenderItem, at time: CMTime) -> Int? {
        Self.activeWordIndex(words: item.words, at: time)
    }

    /// Index of the word to highlight at `time`. A word whose range contains
    /// `time` wins; otherwise the most-recently-started word is *held* so the
    /// karaoke highlight doesn't snap back to the un-highlighted base fill in
    /// the gaps ASR leaves between words, or after the final word while the line
    /// is still on screen (R3.3). Before the first word starts, returns nil so
    /// the line renders idle. Pure + `static` so it's unit-testable without a
    /// compositor instance; `words` are assumed sorted ascending by start.
    nonisolated static func activeWordIndex(words: [WordTiming]?, at time: CMTime) -> Int? {
        guard let words, !words.isEmpty else { return nil }
        for (i, word) in words.enumerated() where word.range.containsTime(time) {
            return i
        }
        var held: Int?
        for (i, word) in words.enumerated() where word.range.start <= time {
            held = i
        }
        return held
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

    /// A directional bars-swipe transition via Core Image.
    nonisolated private func wipe(outgoing: CIImage, incoming: CIImage,
                                  progress: Float, angle: Double) -> CIImage {
        let filter = CIFilter.barsSwipeTransition()
        filter.inputImage = outgoing
        filter.targetImage = incoming
        filter.time = progress
        filter.angle = Float(angle)
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

    // `internal` (not `private`) so the test target can verify the identity
    // pass-through invariant — an empty effect chain must return the input
    // image byte-for-byte (R5.1 from feature-colour-grading / EffectsTests).
    nonisolated func applyEffectChain(_ image: CIImage,
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
        guard let cg = Self.context(for: .sRGB).createCGImage(image, from: extent) else {
            return nil
        }
        return CIImage(cgImage: cg)
    }

    nonisolated private func applyColourGrade(_ image: CIImage, grade: ColourGrade) -> CIImage {
        return image
            .applying(when: grade.exposure != 0) {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = $0
                filter.ev = grade.exposure
                return filter.outputImage
            }
            .applying(when: grade.contrast != 1 || grade.saturation != 1) {
                let filter = CIFilter.colorControls()
                filter.inputImage = $0
                filter.contrast = grade.contrast
                filter.saturation = grade.saturation
                return filter.outputImage
            }
            .applying(when: grade.temperatureOffset != 0 || grade.tintOffset != 0) {
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = $0
                filter.neutral = CIVector(x: 6500, y: 0)
                filter.targetNeutral = CIVector(x: 6500 + CGFloat(grade.temperatureOffset), y: CGFloat(grade.tintOffset))
                return filter.outputImage
            }
    }

    // MARK: - Skin smoothing kernels

    /// Metal Shading Language source for the skin-smoothing kernels. MSL (not the
    /// deprecated Core Image Kernel Language that `CIColorKernel(source:)` took),
    /// compiled once at runtime via `CIKernel.kernels(withMetalString:)`. Runtime
    /// compilation is used rather than a precompiled `.ci.metal` → `metallib`
    /// because the metallib path depends on the Metal toolchain's `-cikernel`
    /// link flag being threaded through the build, which isn't reliable through
    /// the project's synchronized file-system groups; compiling the string keeps
    /// the kernels working in every bundle/build context (app, test host, CI).
    private static let kernelSource = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[ stitchable ]] float4 skinMask(coreimage::sample_t image, float warmthBias, float luminanceGate) {
            float alpha = image.a;
            float3 rgb = alpha > 0.0 ? image.rgb / alpha : float3(0.0);
            float y  = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b;
            float cb = 0.5 - 0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b;
            float cr = 0.5 + 0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b;
            float cbMin = 0.3 + warmthBias * 0.05;
            float cbMax = 0.5 + warmthBias * 0.05;
            float crMin = 0.5 + warmthBias * 0.05;
            float crMax = 0.7 + warmthBias * 0.05;
            float cbDist = smoothstep(cbMin - 0.05, cbMin, cb) * (1.0 - smoothstep(cbMax, cbMax + 0.05, cb));
            float crDist = smoothstep(crMin - 0.05, crMin, cr) * (1.0 - smoothstep(crMax, crMax + 0.05, cr));
            float skinProb = cbDist * crDist;
            float lumGate = smoothstep(0.0, luminanceGate * 0.5, y) * (1.0 - smoothstep(1.0 - luminanceGate * 0.5, 1.0, y));
            skinProb *= lumGate;
            skinProb *= alpha;
            return float4(skinProb, skinProb, skinProb, alpha);
        }

        [[ stitchable ]] float4 skinBlend(coreimage::sample_t original, coreimage::sample_t smoothed, coreimage::sample_t mask, float strength) {
            float maskVal = mask.r * strength;
            return mix(original, smoothed, maskVal);
        }
        """

    /// Both colour kernels, compiled once from `kernelSource`. A compile failure
    /// leaves the kernels nil (logged) and degrades skin smoothing to a no-op
    /// rather than crashing the render path.
    private static let skinKernels: (mask: CIColorKernel, blend: CIColorKernel)? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: kernelSource),
              let mask = kernels.first(where: { $0.name == "skinMask" }) as? CIColorKernel,
              let blend = kernels.first(where: { $0.name == "skinBlend" }) as? CIColorKernel else {
            os_log(.error, "Skin-smoothing Metal kernels failed to compile — effect disabled")
            return nil
        }
        return (mask, blend)
    }()

    private static var skinMaskKernel: CIColorKernel? { skinKernels?.mask }
    private static var skinBlendKernel: CIColorKernel? { skinKernels?.blend }

    // MARK: - Skin smoothing

    nonisolated static let skinSmoothReferenceHeight: CGFloat = 1080
    nonisolated static let skinSmoothReferenceMaxRadius: Float = 10

    /// Maps user strength to a source-pixel Gaussian radius. Radius is authored
    /// against a 1080p source frame, then scaled by the actual source height so
    /// 4K footage does not look half as smooth as 1080p at the same strength.
    nonisolated static func skinSmoothBlurRadius(strength: Float, imageHeight: CGFloat) -> Float {
        let clampedStrength = max(0, min(1, strength))
        let heightScale: Float
        if imageHeight.isFinite, imageHeight > 0 {
            heightScale = Float(imageHeight / skinSmoothReferenceHeight)
        } else {
            heightScale = 1
        }
        return clampedStrength * skinSmoothReferenceMaxRadius * heightScale
    }

    /// Applies skin smoothing using a chroma-based skin-tone mask and masked Gaussian blur proxy.
    /// Internal (not private) so the render-path test can exercise the compiled MSL kernels
    /// directly — a missing `metallib` or renamed kernel makes this return `nil`.
    nonisolated func applySkinSmooth(_ image: CIImage, params: SkinSmoothEffect, at time: CMTime) -> CIImage? {
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

        // Apply a moderate blur — radius scales with strength and source height.
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = clamped
        blurFilter.radius = Self.skinSmoothBlurRadius(strength: strength,
                                                      imageHeight: image.extent.height)
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
        // .cube files are authored against sRGB, irrespective of the project's
        // working space — the LUT's input axes are sRGB code values.
        filter.colorSpace = WorkingColourSpace.sRGB.cgColorSpace
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

// MARK: - Filter-chain plumbing

private extension CIImage {
    /// Routes the image through `transform` when `condition` holds, otherwise
    /// passes it through unchanged. A `nil` result from `transform` falls back
    /// to the input — collapsing the repeated "set `inputImage` / take
    /// `outputImage ?? prior`" boilerplate into one chainable step.
    nonisolated func applying(when condition: Bool, _ transform: (CIImage) -> CIImage?) -> CIImage {
        guard condition else { return self }
        return transform(self) ?? self
    }
}
