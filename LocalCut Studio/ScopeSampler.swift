import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import os

/// One frame's worth of scope data, sampled from the compositor's output.
struct ScopeSample: Sendable, Equatable {
    /// Per-X-column luma histogram (low x → low index). 32 columns, 64 bins each.
    var waveform: [WaveformColumn]
    /// Per-cell average chroma offsets (U, V) in the [-0.5, 0.5] plane. 8×8 grid.
    var vectorscope: [VectorPoint]
    /// Monotonic compositor timestamp at sample time. Used by the UI to drop
    /// out-of-order samples (publish() hops to the main actor via unstructured
    /// Tasks, which can re-order).
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
/// waveform + vectorscope data, and stores the latest sample behind a lock.
/// `ScopesView` pulls the latest snapshot on a SwiftUI `TimelineView` tick —
/// the sampler holds no SwiftUI / Observation state because the compositor
/// reaches it from a nonisolated context, and a `@MainActor`-isolated
/// singleton would force the entire sampling path through the main actor.
final class ScopeSampler: @unchecked Sendable {

    /// `nonisolated(unsafe)` opts the static out of the project's default
    /// `MainActor` isolation — the type itself is `@unchecked Sendable` and
    /// all of its accessors are explicitly nonisolated, so a non-isolated
    /// singleton is safe.
    nonisolated(unsafe) static let shared = ScopeSampler()

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

    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var enabled: Bool = false
        var lastSampleAt: TimeInterval = 0
        var latest: ScopeSample?
        /// Bumped on each `publish`; the view reads this so the canvas redraws
        /// only when a new sample lands, not on every TimelineView tick.
        var revision: Int = 0
    }

    nonisolated init() {}

    // MARK: - Enable / gate

    /// The scope panel sets this when it appears / disappears.
    nonisolated func setEnabled(_ flag: Bool) {
        state.withLock { current in
            current.enabled = flag
            if !flag {
                // Clear the last sample so reappearing doesn't show stale
                // pixels for one frame before the next sample arrives.
                current.latest = nil
            }
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

    /// Stores `sample` as the latest, dropping it on the floor if a newer
    /// sample (by `generatedAt`) already arrived — `startRequest(_:)` is
    /// dispatched concurrently for separate frame requests by AVFoundation,
    /// so two `publish` calls can race and an older frame could otherwise
    /// overwrite a newer one.
    nonisolated func publish(_ sample: ScopeSample) {
        state.withLock { current in
            if let prior = current.latest, prior.generatedAt > sample.generatedAt {
                return
            }
            current.latest = sample
            current.revision &+= 1
        }
    }

    /// The latest published sample plus the publish revision. The UI reads
    /// this from a `TimelineView` tick at the panel's refresh rate.
    nonisolated var snapshot: (sample: ScopeSample?, revision: Int) {
        state.withLock { ($0.latest, $0.revision) }
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

    /// Per-column luma histograms. The image is first folded into a single-
    /// channel luma image (BT.709 weights) so `areaHistogram` returns a
    /// luma-only distribution; weighting independent R/G/B histograms after
    /// the fact would not produce a luma histogram for saturated colours
    /// (a pure red would split across G/B's zero bin and R's high bin).
    private nonisolated func makeWaveform(image: CIImage, context: CIContext,
                                          colorSpace: CGColorSpace) -> [WaveformColumn] {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else {
            return []
        }

        let lumaImage = lumaOnly(image)
        let columns = Self.waveformColumnCount
        let bins = Self.waveformBinCount
        let columnWidth = extent.width / CGFloat(columns)

        var result: [WaveformColumn] = []
        result.reserveCapacity(columns)

        // First pass: collect raw R-channel histograms per column (we just
        // computed the luma image into R).
        var rawColumns: [[Float]] = []
        rawColumns.reserveCapacity(columns)
        var globalMax: Float = 0
        for i in 0..<columns {
            let columnRect = CGRect(
                x: extent.origin.x + CGFloat(i) * columnWidth,
                y: extent.origin.y,
                width: columnWidth,
                height: extent.height)
            let raw = lumaHistogram(image: lumaImage, rect: columnRect, bins: bins,
                                    context: context, colorSpace: colorSpace)
            for v in raw where v > globalMax { globalMax = v }
            rawColumns.append(raw)
        }

        // Normalise across all columns so the brightest bin sits at 1.0 and
        // relative magnitudes between columns are preserved (per-column
        // normalisation would flatten the relationship between columns).
        let scale: Float = globalMax > 0 ? 1.0 / globalMax : 0
        for i in 0..<columns {
            let normalised = scale > 0 ? rawColumns[i].map { $0 * scale } : rawColumns[i]
            let x = Float((CGFloat(i) + 0.5) / CGFloat(columns))
            result.append(WaveformColumn(x: x, bins: normalised))
        }
        return result
    }

    /// Folds RGB into the R channel using BT.709 luma weights. G, B are zeroed
    /// so `areaHistogram` reports a single-channel luma distribution in R.
    private nonisolated func lumaOnly(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        filter.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? image
    }

    /// Runs `CIFilter.areaHistogram` on a luma-only image slice, reading the R
    /// channel back as float counts. `.RGBAf` is required: `areaHistogram`
    /// reports raw pixel counts in each channel, which routinely exceed 1.0
    /// for any slice with more than one pixel per bin — an 8-bit readback
    /// would clamp every populated bin to 255 and flatten the distribution.
    private nonisolated func lumaHistogram(image: CIImage, rect: CGRect, bins: Int,
                                           context: CIContext,
                                           colorSpace: CGColorSpace) -> [Float] {
        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = rect
        filter.count = bins
        filter.scale = 1
        guard let output = filter.outputImage else { return Array(repeating: 0, count: bins) }

        // Each output pixel is bins-wide × 1-tall RGBA float; we read the R
        // channel as the luma count.
        let pixelCount = bins
        var pixels = [Float](repeating: 0, count: pixelCount * 4)
        let bytesPerRow = pixelCount * 4 * MemoryLayout<Float>.size
        let outputRect = CGRect(x: 0, y: 0, width: pixelCount, height: 1)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: bytesPerRow,
                           bounds: outputRect, format: .RGBAf, colorSpace: colorSpace)
        }

        var out = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            out[i] = max(0, pixels[i * 4 + 0])
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
    /// `.RGBAf` so cell averages don't get quantised to 8-bit before we
    /// convert to UV.
    private nonisolated func averageRGB(image: CIImage, rect: CGRect, context: CIContext,
                                        colorSpace: CGColorSpace) -> (r: Float, g: Float, b: Float) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect
        guard let output = filter.outputImage else { return (0, 0, 0) }

        var pixel: [Float] = [0, 0, 0, 0]
        let bytesPerRow = 4 * MemoryLayout<Float>.size
        let outRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        pixel.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: bytesPerRow,
                           bounds: outRect, format: .RGBAf, colorSpace: colorSpace)
        }
        return (max(0, pixel[0]), max(0, pixel[1]), max(0, pixel[2]))
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
