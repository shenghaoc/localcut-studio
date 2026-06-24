import Foundation
import CoreImage
import CoreGraphics
import os
import LocalCutCore

/// One frame's worth of scope data, sampled from the compositor's output.
struct ScopeSample: Sendable, Equatable {
    /// Per-X-column luma histogram (low x → low index). 32 columns, 64 bins each.
    var waveform: [WaveformColumn]
    /// Per-readback-pixel chroma offsets (U, V) in the [-0.5, 0.5] plane.
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
    /// Upper bound for the single scope readback. 160×90 is enough for a
    /// dense vectorscope trace and 5 source samples per waveform column at
    /// 16:9, without making every composited frame read back at full preview
    /// resolution.
    nonisolated static let readbackMaxWidth: Int = 160
    nonisolated static let readbackMaxHeight: Int = 90

    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct ScopeReadback: Sendable {
        let width: Int
        let height: Int
        let pixels: [Float]
    }

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
                current.revision &+= 1
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

    /// The latest published sample plus the publish revision. The UI polls this
    /// cheaply and only invalidates SwiftUI state when `revision` changes.
    nonisolated var snapshot: (sample: ScopeSample?, revision: Int) {
        state.withLock { ($0.latest, $0.revision) }
    }

    // MARK: - Sampling

    /// Synchronously computes a scope sample from `image`. Pure / testable —
    /// the caller supplies the CIContext (and thus the working colour space).
    nonisolated func sample(image: CIImage, context: CIContext,
                            colorSpace: CGColorSpace) -> ScopeSample {
        guard let readback = makeReadback(image: image, context: context, colorSpace: colorSpace) else {
            return ScopeSample(waveform: [], vectorscope: [], generatedAt: Date())
        }
        let (waveform, vectorscope) = extractScopes(from: readback)
        return ScopeSample(waveform: waveform, vectorscope: vectorscope, generatedAt: Date())
    }

    // MARK: Readback

    /// Render the frame into one bounded RGBA float buffer. Waveform and
    /// vectorscope derive from this same buffer, avoiding the old N+1 filter
    /// readbacks (32 histogram renders plus a vectorscope render).
    private nonisolated func makeReadback(image: CIImage, context: CIContext,
                                          colorSpace: CGColorSpace) -> ScopeReadback? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }

        let scale = min(
            1,
            min(CGFloat(Self.readbackMaxWidth) / extent.width,
                CGFloat(Self.readbackMaxHeight) / extent.height))
        let width = max(2, Int((extent.width * scale).rounded(.toNearestOrAwayFromZero)))
        let height = max(2, Int((extent.height * scale).rounded(.toNearestOrAwayFromZero)))
        let normalised = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                               y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                               y: CGFloat(height) / extent.height))

        var pixels = [Float](repeating: 0, count: width * height * 4)
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        let outRect = CGRect(x: 0, y: 0, width: width, height: height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(normalised, toBitmap: base, rowBytes: bytesPerRow,
                           bounds: outRect, format: .RGBAf, colorSpace: colorSpace)
        }
        return ScopeReadback(width: width, height: height, pixels: pixels)
    }

    // MARK: Scope extraction (single-pass)

    /// Single-pass extraction of waveform and vectorscope data from one
    /// readback. Both scopes derive from the same pixel buffer, so combining
    /// them eliminates redundant `displayChannel` calls and improves cache
    /// locality — each pixel's RGB values are consumed once for both scopes.
    ///
    /// Luma clamping is omitted because `displayChannel` already constrains
    /// r/g/b to [0, 1] and the BT.709 coefficients (0.2126 + 0.7152 + 0.0722)
    /// sum to 1.0, so the weighted sum is mathematically guaranteed to be in
    /// [0, 1]. The UV conversion is inlined to avoid `rgbToUV` re-applying
    /// `displayChannel` to already-processed values.
    private nonisolated func extractScopes(from readback: ScopeReadback) -> (waveform: [WaveformColumn], vectorscope: [VectorPoint]) {
        let columns = Self.waveformColumnCount
        let bins = Self.waveformBinCount
        var counts = [Float](repeating: 0, count: columns * bins)
        var vectorscopePoints: [VectorPoint] = []
        vectorscopePoints.reserveCapacity(readback.width * readback.height)

        var offset = 0
        for _ in 0..<readback.height {
            for x in 0..<readback.width {
                let r = Self.displayChannel(readback.pixels[offset + 0])
                let g = Self.displayChannel(readback.pixels[offset + 1])
                let b = Self.displayChannel(readback.pixels[offset + 2])
                offset += 4

                // Waveform binning — luma guaranteed in [0, 1] by BT.709
                // coefficients summing to 1.0 on pre-clamped inputs.
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let column = min(columns - 1, x * columns / readback.width)
                let bin = min(bins - 1, Int(luma * Float(bins - 1)))
                counts[column * bins + bin] += 1

                // Vectorscope point — BT.601 UV inlined to skip redundant
                // `displayChannel` calls inside `rgbToUV`.
                let y601 = 0.299 * r + 0.587 * g + 0.114 * b
                let u = (b - y601) * 0.564
                let v = (r - y601) * 0.713
                vectorscopePoints.append(VectorPoint(u: u, v: v))
            }
        }

        // Per-column normalisation: each column's tallest bin sits at 1.0.
        // A global normaliser would let a single specular highlight in one
        // column flatten every other column to near-zero, defeating the
        // panel's purpose for typical footage. Cross-column luma magnitude
        // is therefore *not* preserved by this scope — a per-row average is
        // a Phase 38 extension.
        var waveform: [WaveformColumn] = []
        waveform.reserveCapacity(columns)
        for i in 0..<columns {
            let start = i * bins
            let raw = Array(counts[start..<(start + bins)])
            let columnMax = raw.max() ?? 0
            let normalised: [Float] = columnMax > 0 ? raw.map { $0 / columnMax } : raw
            let x = Float((CGFloat(i) + 0.5) / CGFloat(columns))
            waveform.append(WaveformColumn(x: x, bins: normalised))
        }

        return (waveform, vectorscopePoints)
    }

    /// BT.601 RGB → UV chroma. Returns offsets in [-0.5, 0.5]; (0, 0) ≡ neutral
    /// grey. The vectorscope plots these on the chroma plane.
    nonisolated static func rgbToUV(_ rgb: (r: Float, g: Float, b: Float)) -> (u: Float, v: Float) {
        let r = displayChannel(rgb.r)
        let g = displayChannel(rgb.g)
        let b = displayChannel(rgb.b)
        let y: Float = 0.299 * r + 0.587 * g + 0.114 * b
        let u = (b - y) * 0.564
        let v = (r - y) * 0.713
        return (u, v)
    }

    nonisolated func rgbToUV(_ rgb: (r: Float, g: Float, b: Float)) -> (u: Float, v: Float) {
        Self.rgbToUV(rgb)
    }

    private nonisolated static func displayChannel(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return clamped01(value)
    }

    private nonisolated static func clamped01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}
