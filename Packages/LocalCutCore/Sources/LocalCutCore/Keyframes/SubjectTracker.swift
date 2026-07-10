import Foundation
import CoreMedia

// MARK: - One-Euro Filter

/// A One-Euro filter for smooth, low-latency tracking of a noisy signal.
///
/// Reference: Casiez et al., "1€ Filter: A Simple Speed-based Low-pass Filter
/// for Noisy Input in Interactive Systems" (CHI 2012).
public struct OneEuroFilter: Sendable {
    /// Minimum cutoff frequency in Hz (lower = smoother).
    public let minCutoff: Float
    /// Speed coefficient (higher = less lag during fast motion).
    public let beta: Float
    /// Derivative cutoff frequency.
    public let dCutoff: Float

    private var x: LowPassFilter
    private var dx: LowPassFilter
    private var initialized = false

    /// The last filtered value.
    public var value: Float { x.value }

    public init(minCutoff: Float = 1.0, beta: Float = 0.007, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
        self.x = LowPassFilter(alpha: 0)
        self.dx = LowPassFilter(alpha: 0)
    }

    /// Filters a new value. `dt` is the time since the last sample in seconds.
    public mutating func filter(_ value: Float, dt: Float) -> Float {
        guard dt > 0 else { return value }
        if !initialized {
            x = LowPassFilter(alpha: 1.0)
            dx = LowPassFilter(alpha: 1.0)
            initialized = true
            return x.filter(value)
        }

        let dxValue = (value - x.value) / dt
        let edx = dx.filter(dxValue, alpha: alpha(dt: dt, cutoff: dCutoff))
        let cutoff = minCutoff + beta * abs(edx)
        return x.filter(value, alpha: alpha(dt: dt, cutoff: cutoff))
    }

    /// Resets the filter state.
    public mutating func reset() {
        x = LowPassFilter(alpha: 0)
        dx = LowPassFilter(alpha: 0)
        initialized = false
    }

    private func alpha(dt: Float, cutoff: Float) -> Float {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}

/// A simple low-pass filter used internally by OneEuroFilter.
internal struct LowPassFilter: Sendable {
    var alpha: Float
    var value: Float = 0
    private var initialized = false

    init(alpha: Float) {
        self.alpha = alpha
    }

    mutating func filter(_ value: Float, alpha: Float? = nil) -> Float {
        if let alpha { self.alpha = alpha }
        if !initialized {
            self.value = value
            initialized = true
            return value
        }
        self.value = self.alpha * value + (1 - self.alpha) * self.value
        return self.value
    }
}

// MARK: - Subject Tracker

/// Tracks a single subject across frames using IoU association and One-Euro
/// smoothing on the tracked centroid.
public struct SubjectTracker: Sendable {
    /// IoU threshold for associating detections across frames.
    public let iouThreshold: Float
    /// One-Euro filter for the x coordinate.
    private var filterX: OneEuroFilter
    /// One-Euro filter for the y coordinate.
    private var filterY: OneEuroFilter
    /// Last known bounding box for IoU association.
    private var lastBBox: NormalizedRect?
    /// Whether the tracker has been initialised with a detection.
    private var hasTrack: Bool = false

    public init(
        iouThreshold: Float = 0.3,
        minCutoff: Float = 1.0,
        beta: Float = 0.007
    ) {
        self.iouThreshold = iouThreshold
        self.filterX = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        self.filterY = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }

    /// Resets the tracker state (e.g., at a shot boundary).
    public mutating func reset() {
        filterX.reset()
        filterY.reset()
        lastBBox = nil
        hasTrack = false
    }

    /// Processes a set of detections at a given time and returns a smoothed
    /// trajectory sample.
    ///
    /// - Parameters:
    ///   - detections: Detected subjects at this frame.
    ///   - time: Presentation timestamp of the frame.
    ///   - dt: Time since last frame in seconds.
    /// - Returns: A trajectory sample with the smoothed centre, or `nil` if
    ///   no detection could be associated.
    public mutating func track(
        detections: [DetectedSubject],
        time: CMTime,
        dt: Float
    ) -> SubjectTrajectorySample? {
        let bestMatch = selectBestMatch(detections: detections)

        if let match = bestMatch {
            let cx: Float
            let cy: Float
            if hasTrack, let last = lastBBox, match.bbox.iou(with: last) >= iouThreshold {
                // Associated: smooth the centroid
                cx = filterX.filter(match.bbox.center.x, dt: dt)
                cy = filterY.filter(match.bbox.center.y, dt: dt)
            } else {
                // New track or lost: reinitialise filter
                filterX.reset()
                filterY.reset()
                cx = filterX.filter(match.bbox.center.x, dt: dt)
                cy = filterY.filter(match.bbox.center.y, dt: dt)
            }
            lastBBox = match.bbox
            hasTrack = true
            return SubjectTrajectorySample(time: time, center: NormalizedPoint(x: cx, y: cy), detected: true)
        }

        // No detection: extrapolate with last smoothed value
        if hasTrack {
            let lastCenter = NormalizedPoint(x: filterX.value, y: filterY.value)
            return SubjectTrajectorySample(time: time, center: lastCenter, detected: false)
        }

        return nil
    }

    /// Selects the best detection: largest and most central.
    private func selectBestMatch(detections: [DetectedSubject]) -> DetectedSubject? {
        guard !detections.isEmpty else { return nil }
        // Score = area * centrality (distance from 0.5, 0.5 penalised)
        return detections.max { a, b in
            score(detection: a) < score(detection: b)
        }
    }

    /// Scores a detection by size and centrality.
    private func score(detection: DetectedSubject) -> Float {
        let center = detection.bbox.center
        let dx = center.x - 0.5
        let dy = center.y - 0.5
        let centrality = 1.0 - sqrt(dx * dx + dy * dy) * 0.5
        return detection.bbox.area * centrality * detection.confidence
    }
}
