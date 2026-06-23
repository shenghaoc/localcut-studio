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
    /// Compositor timestamp at sample time. `publish(_:)` is invoked
    /// concurrently from AVFoundation's per-frame queues; the lock-protected
    /// `generatedAt` comparison there ensures an older frame can never
    /// overwrite a newer one.
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
final class ScopeSampler: Sendable {

    /// `nonisolated` opts the static out of the project's default `MainActor`
    /// isolation — the type is `@unchecked Sendable` with explicitly
    /// nonisolated accessors, so the compiler proves the singleton safe
    /// without the `(unsafe)` escape hatch.
    nonisolated static let shared = ScopeSampler()

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
    nonisolated func shouldSample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
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

        // Per-column normalisation: each column's tallest bin sits at 1.0.
        // A global normaliser would let a single specular highlight in one
        // column flatten every other column to near-zero, defeating the
        // panel's purpose for typical footage. Cross-column luma magnitude
        // is therefore *not* preserved by this scope — a per-row average is
        // a Phase 38 extension.
        for i in 0..<columns {
            let columnRect = CGRect(
                x: extent.origin.x + CGFloat(i) * columnWidth,
                y: extent.origin.y,
                width: columnWidth,
                height: extent.height)
            let raw = lumaHistogram(image: lumaImage, rect: columnRect, bins: bins,
                                    context: context, colorSpace: colorSpace)
            let columnMax = raw.max() ?? 0
            let normalised: [Float] = columnMax > 0 ? raw.map { $0 / columnMax } : raw
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
        // Scale the image down to grid×grid in one GPU pass, then read back
        // the entire grid in a single `context.render` call — avoids 64
        // sequential GPU-to-CPU round-trips that the per-cell `areaAverage`
        // loop would cause.
        let normalised = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                               y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(grid) / extent.width,
                                               y: CGFloat(grid) / extent.height))

        var pixels = [Float](repeating: 0, count: grid * grid * 4)
        let bytesPerRow = grid * 4 * MemoryLayout<Float>.size
        let outRect = CGRect(x: 0, y: 0, width: grid, height: grid)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(normalised, toBitmap: base, rowBytes: bytesPerRow,
                           bounds: outRect, format: .RGBAf, colorSpace: colorSpace)
        }

        var result: [VectorPoint] = []
        result.reserveCapacity(grid * grid)
        for row in 0..<grid {
            for col in 0..<grid {
                let offset = (row * grid + col) * 4
                let r = max(0, pixels[offset + 0])
                let g = max(0, pixels[offset + 1])
                let b = max(0, pixels[offset + 2])
                let (u, v) = rgbToUV((r, g, b))
                result.append(VectorPoint(u: u, v: v))
            }
        }
        return result
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
