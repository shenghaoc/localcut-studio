import Foundation
import CoreMedia

// MARK: - Smart Reframe Models (Phase 33)

/// Detection mode reported per analysis run.
public enum ReframeDetectionMode: String, Codable, Hashable, Sendable {
    /// Only face detections were used.
    case face
    /// Only saliency detections were used (no faces found).
    case saliency
    /// Both face and saliency detections were used across the run.
    case mixed
}

/// Configuration for a reframe analysis run.
public struct ReframeOptions: Hashable, Sendable {
    /// Target aspect ratio as width:height (e.g. 9.0/16.0 for vertical).
    public var targetAspectRatio: Float
    /// Analysis sample rate in frames per second.
    public var analysisFPS: Double
    /// Maximum velocity bound in normalised units/second.
    public var velocityBound: Float
    /// Maximum acceleration bound in normalised units/second².
    public var accelerationBound: Float
    /// Chi-squared distance threshold for shot-boundary detection.
    public var shotBoundaryThreshold: Float
    /// Action-safe region half-extent from centre (0.45 = centre ± 0.45).
    public var actionSafeHalfExtent: Float

    public init(
        targetAspectRatio: Float = 9.0 / 16.0,
        analysisFPS: Double = 2.0,
        velocityBound: Float = 0.3,
        accelerationBound: Float = 0.5,
        shotBoundaryThreshold: Float = 0.5,
        actionSafeHalfExtent: Float = 0.45
    ) {
        self.targetAspectRatio = targetAspectRatio
        self.analysisFPS = max(0.5, min(10, analysisFPS))
        self.velocityBound = velocityBound
        self.accelerationBound = accelerationBound
        self.shotBoundaryThreshold = shotBoundaryThreshold
        self.actionSafeHalfExtent = actionSafeHalfExtent
    }
}

/// A detected subject at a single frame.
public struct DetectedSubject: Hashable, Sendable {
    /// Normalised bounding box in source coordinates (0–1).
    public var bbox: NormalizedRect
    /// Confidence of the detection (0–1).
    public var confidence: Float
    /// Whether this came from face or saliency detection.
    public var isFace: Bool

    public init(bbox: NormalizedRect, confidence: Float, isFace: Bool) {
        self.bbox = bbox
        self.confidence = confidence
        self.isFace = isFace
    }
}

/// A 2D point in normalised coordinates.
public struct NormalizedPoint: Hashable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// A normalised rectangle (origin top-left, 0–1 coordinate space).
public struct NormalizedRect: Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Centre of the rectangle.
    public var center: NormalizedPoint {
        NormalizedPoint(x: x + width / 2, y: y + height / 2)
    }

    /// Area of the rectangle.
    public var area: Float { width * height }

    /// Intersection over union with another rect.
    public func iou(with other: NormalizedRect) -> Float {
        let x1 = max(x, other.x)
        let y1 = max(y, other.y)
        let x2 = min(x + width, other.x + other.width)
        let y2 = min(y + height, other.y + other.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = area + other.area - intersection
        guard union > 0 else { return 0 }
        return intersection / union
    }
}

/// A tracked subject sample after IoU association and One-Euro smoothing.
public struct SubjectTrajectorySample: Hashable, Sendable {
    /// Presentation timestamp of the source frame.
    public var time: CMTime
    /// Smoothed centre position in normalised source coordinates (0–1).
    public var center: NormalizedPoint
    /// Detection mode for this frame.
    public var detected: Bool

    public init(time: CMTime, center: NormalizedPoint, detected: Bool) {
        self.time = time
        self.center = center
        self.detected = detected
    }
}

/// A detected shot boundary.
public struct ShotBoundary: Hashable, Sendable {
    /// Presentation timestamp of the cut point.
    public var time: CMTime
    /// Chi-squared distance that triggered the boundary.
    public var distance: Float

    public init(time: CMTime, distance: Float) {
        self.time = time
        self.distance = distance
    }
}

/// A proposed reframe keyframe before user review.
public struct ReframeKeyframeProposal: Hashable, Identifiable, Sendable {
    public let id: UUID
    /// Time in clip-source-local coordinates.
    public var time: CMTime
    /// Proposed transform value.
    public var value: Transform2D
    /// Easing: `nil` = linear, otherwise Bézier handles.
    public var incomingHandle: KeyframeHandle?
    public var outgoingHandle: KeyframeHandle?

    public init(
        id: UUID = UUID(),
        time: CMTime,
        value: Transform2D,
        incomingHandle: KeyframeHandle? = nil,
        outgoingHandle: KeyframeHandle? = nil
    ) {
        self.id = id
        self.time = time
        self.value = value
        self.incomingHandle = incomingHandle
        self.outgoingHandle = outgoingHandle
    }
}

/// The result of a reframe analysis.
public struct ReframeProposal: Hashable, Sendable {
    /// The generated keyframes.
    public var keyframes: [ReframeKeyframeProposal]
    /// Detected shot boundaries.
    public var shotBoundaries: [ShotBoundary]
    /// Detection mode used across the analysis.
    public var detectionMode: ReframeDetectionMode
    /// Number of frames analysed.
    public var framesAnalyzed: Int
    /// Warnings generated during analysis (e.g., safe-zone compliance failure).
    public var warnings: [ReframeWarning]

    public init(
        keyframes: [ReframeKeyframeProposal] = [],
        shotBoundaries: [ShotBoundary] = [],
        detectionMode: ReframeDetectionMode = .face,
        framesAnalyzed: Int = 0,
        warnings: [ReframeWarning] = []
    ) {
        self.keyframes = keyframes
        self.shotBoundaries = shotBoundaries
        self.detectionMode = detectionMode
        self.framesAnalyzed = framesAnalyzed
        self.warnings = warnings
    }
}

/// Warnings generated during reframe analysis.
public enum ReframeWarning: Hashable, Sendable {
    /// Safe-zone compliance could not reach 95% after scale cap.
    case safeZoneComplianceBelowThreshold(compliance: Float, scaleUsed: Float)
    /// Very short clip received start/end keyframes only.
    case veryShortClip(duration: Double)
    /// No subject detected in a section.
    case noSubjectDetected(timeRange: CMTimeRange)
}

/// Progress updates from the reframe analyzer.
public enum ReframeProgress: Sendable {
    case preparing
    case analyzing(frame: Int, totalFrames: Int)
    case generatingKeyframes
    case completed(ReframeProposal)
    case cancelled
    case failed(String)
}
