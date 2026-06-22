import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Observation
import os

/// One frame's worth of scope data, sampled from the compositor's output.
struct ScopeSample: Sendable, Equatable {
    /// Per-X-column luma histogram (low x → low index). 32 columns, 64 bins each.
    var waveform: [WaveformColumn]
    /// Per-cell average chroma offsets (U, V) in the [-0.5, 0.5] plane. 8×8 grid.
    var vectorscope: [VectorPoint]
    var generatedAt: Date

    static let empty = ScopeSample(waveform: [], vectorscope: [], generatedAt: Date(timeIntervalSince1970: 0))
}

/// One vertical histogram of a thin column slice across the frame.
struct WaveformColumn: Sendable, Equatable {
    /// Normalised x position in [0, 1] (column centre).
    var x: Float
    /// Luma histogram, low → high luma. Values are in [0, 1] (normalised by max bin).
    var bins: [Float]

    /// Convenience for tests: any bin with a value above the threshold.
    var hasContent: Bool { bins.contains(where: { $0 > 0 }) }
}

/// One (U, V) chroma offset, derived from a cell average colour. Both axes are
/// normalised to [-0.5, 0.5] using the BT.601 RGB→YCbCr conversion.
struct VectorPoint: Sendable, Equatable {
    var u: Float
    var v: Float
}

/// Shared 30 Hz sampler: receives every compositor frame (gated), computes
/// waveform + vectorscope data, and republishes the latest sample. `ScopesView`
/// observes the singleton through SwiftUI's `Observable` change-tracking by
/// reading `revision` inside `body`.
@Observable
final class ScopeSampler: @unchecked Sendable {

    static let shared = ScopeSampler()

    /// 1 / 30 s — the floor between two samples. A 60 fps preview pays the
    /// sampling cost on roughly every other frame and the user can't see the
    /// difference past this rate.
    nonisolated static let minIntervalSeconds: Double = 1.0 / 30.0

    /// Column slice count for the waveform. 32 is dense enough to look like a
    /// continuous luma trace at preview size, sparse enough to render cheaply.
    nonisolated static let waveformColumnCount: Int = 32
    /// Bins per column for the waveform — luma distribution within the slice.
    nonisolated static let waveformBinCount: Int = 64
    /// Grid resolution for the vectorscope (cells per side). 8×8 = 64 points.
    nonisolated static let vectorscopeGridSize: Int = 8

    /// Whether `body` of `ScopesView` is currently on screen — when off, the
    /// gate short-circuits before any filter work runs. Read on the
    /// compositor's nonisolated queue and written from the SwiftUI MainActor.
    @ObservationIgnored private let state = OSAllocatedUnfairLock(initialState: State())

    /// Bumps on each `publish` so the observing view re-renders only on a new sample.
    private(set) var revision: Int = 0
    /// The latest published sample. `nil` until the first frame arrives.
    private(set) var latest: ScopeSample?

    private struct State {
        var enabled: Bool = false
        var lastSampleAt: TimeInterval = 0
    }

    nonisolated init() {}

    // MARK: - Enable / gate

    /// The scope panel sets this when it appears / disappears.
    @MainActor
    func setEnabled(_ flag: Bool) {
        state.withLock { $0.enabled = flag }
        if !flag {
            // Clear the last sample so reappearing doesn't show stale pixels
            // for one frame before the next sample arrives.
            latest = nil
        }
    }

    nonisolated var isEnabled: Bool {
        state.withLock { $0.enabled }
    }

    /// Called once per frame by `EffectCompositor.startRequest(_:)`. Returns
    /// true when the gate allows a sample (panel visible AND ≥ 1/30 s since
    /// the previous sample).
    nonisolated func shouldSample(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Bool {
        state.withLock { current in
            guard current.enabled else { return false }
            if now - current.lastSampleAt < Self.minIntervalSeconds { return false }
            current.lastSampleAt = now
            return true
        }
    }

    /// Publishes a sample so the UI re-renders. Hops to the main actor because
    /// the published properties drive SwiftUI observation.
    func publish(_ sample: ScopeSample) {
        Task { @MainActor in
            self.latest = sample
            self.revision &+= 1
        }
    }

    // MARK: - Sampling

    /// Synchronously computes a scope sample from `image`. Pure / testable —
    /// the caller supplies the CIContext (and thus the working colour space).
    nonisolated func sample(image: CIImage, context: CIContext,
                            colorSpace: CGColorSpace) -> ScopeSample {
        ScopeSample(
            waveform: makeWaveform(image: image, context: context, colorSpace: colorSpace),
            vectorscope: makeVectorscope(image: image, context: context, colorSpace: colorSpace),
            generatedAt: Date())
    }

    // MARK: Waveform

    private nonisolated func makeWaveform(image: CIImage, context: CIContext,
                                          colorSpace: CGColorSpace) -> [WaveformColumn] {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else {
            return []
        }

        let columns = Self.waveformColumnCount
        let bins = Self.waveformBinCount
        let columnWidth = extent.width / CGFloat(columns)

        var result: [WaveformColumn] = []
        result.reserveCapacity(columns)

        for i in 0..<columns {
            let columnRect = CGRect(
                x: extent.origin.x + CGFloat(i) * columnWidth,
                y: extent.origin.y,
                width: columnWidth,
                height: extent.height)
            let normalisedX = Float((CGFloat(i) + 0.5) / CGFloat(columns))
            let column = histogramColumn(image: image, rect: columnRect, bins: bins,
                                         context: context, colorSpace: colorSpace)
            result.append(WaveformColumn(x: normalisedX, bins: column))
        }
        return result
    }

    /// Runs `CIFilter.areaHistogram` on a column slice and reads the resulting
    /// 1-pixel-high RGBA image back to a `[Float]` luma histogram. The luma
    /// channel is computed from R/G/B using BT.709 weights; the alpha channel
    /// is discarded.
    private nonisolated func histogramColumn(image: CIImage, rect: CGRect, bins: Int,
                                             context: CIContext,
                                             colorSpace: CGColorSpace) -> [Float] {
        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = rect
        filter.count = bins
        filter.scale = 1
        guard let output = filter.outputImage else { return Array(repeating: 0, count: bins) }

        // areaHistogram produces a bins×1 RGBA image with bin values in each channel.
        let bytesPerRow = bins * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow)
        let outputRect = CGRect(x: 0, y: 0, width: bins, height: 1)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: bytesPerRow,
                           bounds: outputRect, format: .RGBA8, colorSpace: colorSpace)
        }

        var out = [Float](repeating: 0, count: bins)
        var maxValue: Float = 0
        for i in 0..<bins {
            let r = Float(pixels[i * 4 + 0]) / 255
            let g = Float(pixels[i * 4 + 1]) / 255
            let b = Float(pixels[i * 4 + 2]) / 255
            // BT.709 luma weighting — a reasonable approximation across all
            // four working spaces for a coarse scope display.
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            out[i] = luma
            if luma > maxValue { maxValue = luma }
        }
        // Normalise so the tallest bin sits at 1; an empty column stays all zero.
        if maxValue > 0 {
            for i in 0..<bins { out[i] /= maxValue }
        }
        return out
    }

    // MARK: Vectorscope

    private nonisolated func makeVectorscope(image: CIImage, context: CIContext,
                                             colorSpace: CGColorSpace) -> [VectorPoint] {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else {
            return []
        }

        let grid = Self.vectorscopeGridSize
        let cellW = extent.width / CGFloat(grid)
        let cellH = extent.height / CGFloat(grid)

        var result: [VectorPoint] = []
        result.reserveCapacity(grid * grid)

        for row in 0..<grid {
            for col in 0..<grid {
                let cell = CGRect(
                    x: extent.origin.x + CGFloat(col) * cellW,
                    y: extent.origin.y + CGFloat(row) * cellH,
                    width: cellW, height: cellH)
                let rgb = averageRGB(image: image, rect: cell, context: context, colorSpace: colorSpace)
                let (u, v) = rgbToUV(rgb)
                result.append(VectorPoint(u: u, v: v))
            }
        }
        return result
    }

    /// Reads one cell average via `CIFilter.areaAverage` (1×1 output image).
    private nonisolated func averageRGB(image: CIImage, rect: CGRect, context: CIContext,
                                        colorSpace: CGColorSpace) -> (r: Float, g: Float, b: Float) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect
        guard let output = filter.outputImage else { return (0, 0, 0) }

        var pixel: [UInt8] = [0, 0, 0, 0]
        let outRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        pixel.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: 4,
                           bounds: outRect, format: .RGBA8, colorSpace: colorSpace)
        }
        return (Float(pixel[0]) / 255, Float(pixel[1]) / 255, Float(pixel[2]) / 255)
    }

    /// BT.601 RGB → UV chroma. Returns offsets in [-0.5, 0.5]; (0, 0) ≡ neutral
    /// grey. The vectorscope plots these on the chroma plane.
    nonisolated func rgbToUV(_ rgb: (r: Float, g: Float, b: Float)) -> (u: Float, v: Float) {
        let y: Float = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
        let u = (rgb.b - y) * 0.564
        let v = (rgb.r - y) * 0.713
        return (u, v)
    }
}
