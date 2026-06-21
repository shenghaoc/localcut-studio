import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreVideo
import os

// MARK: - Layer metadata for the compositor

struct CompositorLayer {
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let opacity: Float
    let effects: [Effect]
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

    init(timeRange: CMTimeRange, units: [RenderUnit]) {
        self.timeRange = timeRange
        self.units = units
        // A transition tweens its layers across the interval.
        containsTweening = units.contains {
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
        image = applyEffectChain(image, effects: layer.effects)
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

    nonisolated private func applyEffectChain(_ image: CIImage, effects: [Effect]) -> CIImage {
        var result = image
        for effect in effects {
            switch effect {
            case .colourGrade(let grade):
                result = applyColourGrade(result, grade: grade)
            case .lut(bookmark: let data):
                result = applyLUT(result, bookmarkData: data) ?? result
            }
        }
        return result
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

    /// How long a failed LUT load is cached before another attempt: long enough to
    /// avoid per-frame re-resolution/logging, short enough to recover when a file on
    /// a removable/network volume (or one still being written) becomes available.
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
            // Log only on the first failure for this bookmark, not on each retry.
            if case .some(.failed) = prior {} else {
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
