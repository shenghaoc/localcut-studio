import Foundation
import CoreMedia

// MARK: - Shot Boundary Detector (Phase 33)

/// Detects shot boundaries using chi-squared distance on 512-bin RGB histograms.
///
/// Designed as a reusable, narrowly scoped component. Phase 37 (frame
/// interpolation) can consume this after Phase 33 merges.
public struct ShotBoundaryDetector: Sendable {
    /// Number of bins per colour channel.
    public let binsPerChannel: Int
    /// Chi-squared distance threshold for declaring a cut.
    public let threshold: Float
    /// Total bin count (binsPerChannel^3 for RGB).
    public let binCount: Int

    public init(binsPerChannel: Int = 8, threshold: Float = 0.5) {
        self.binsPerChannel = binsPerChannel
        self.threshold = threshold
        self.binCount = binsPerChannel * binsPerChannel * binsPerChannel
    }

    /// Computes a normalised 512-bin RGB histogram from pixel data.
    ///
    /// - Parameters:
    ///   - pixels: Raw pixel bytes in RGB or RGBA format.
    ///   - bytesPerPixel: 3 for RGB, 4 for RGBA.
    ///   - pixelCount: Total number of pixels.
    /// - Returns: Normalised histogram (sums to 1.0).
    public func histogram(pixels: UnsafePointer<UInt8>,
                          bytesPerPixel: Int,
                          pixelCount: Int) -> [Float] {
        var bins = [Float](repeating: 0, count: binCount)
        let step = binsPerChannel
        let stepSq = step * step
        let scale = Float(256) / Float(binsPerChannel)

        for i in 0..<pixelCount {
            let offset = i * bytesPerPixel
            let r = min(Int(Float(pixels[offset]) / scale), binsPerChannel - 1)
            let g = min(Int(Float(pixels[offset + 1]) / scale), binsPerChannel - 1)
            let b = min(Int(Float(pixels[offset + 2]) / scale), binsPerChannel - 1)
            bins[r * stepSq + g * step + b] += 1
        }

        let total = Float(pixelCount)
        guard total > 0 else { return bins }
        for i in 0..<binCount {
            bins[i] /= total
        }
        return bins
    }

    /// Computes chi-squared distance between two histograms.
    ///
    /// χ² = Σ ((h1[i] - h2[i])² / (h1[i] + h2[i]))
    /// When both bins are zero, the term contributes 0.
    public func chiSquaredDistance(_ h1: [Float], _ h2: [Float]) -> Float {
        guard h1.count == h2.count else { return Float.greatestFiniteMagnitude }
        var distance: Float = 0
        for i in 0..<h1.count {
            let sum = h1[i] + h2[i]
            guard sum > 0 else { continue }
            let diff = h1[i] - h2[i]
            distance += (diff * diff) / sum
        }
        return distance
    }

    /// Checks whether the chi-squared distance indicates a shot boundary.
    public func isShotBoundary(distance: Float) -> Bool {
        distance >= threshold
    }

    /// Processes a sequence of frame histograms and returns detected boundaries.
    ///
    /// - Parameters:
    ///   - histograms: Ordered histograms with corresponding timestamps.
    /// - Returns: Detected shot boundaries.
    public func detectBoundaries(in histograms: [(time: CMTime, histogram: [Float])]) -> [ShotBoundary] {
        guard histograms.count >= 2 else { return [] }
        var boundaries: [ShotBoundary] = []
        for i in 1..<histograms.count {
            let distance = chiSquaredDistance(histograms[i - 1].histogram, histograms[i].histogram)
            if isShotBoundary(distance: distance) {
                boundaries.append(ShotBoundary(time: histograms[i].time, distance: distance))
            }
        }
        return boundaries
    }
}
