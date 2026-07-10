import Foundation
import CoreMedia
import CoreGraphics

// MARK: - Screencast Event Log

/// The kind of user interaction recorded during an own-app capture session.
public enum ScreencastEventKind: String, Hashable, Codable, Sendable {
    case mouseDown
    case mouseUp
    case scroll
    case key
}

/// Key-event phase captured for local keyboard events.
public enum ScreencastKeyPhase: String, Hashable, Codable, Sendable {
    case down
    case up
}

/// A single timestamped user interaction captured during recording.
public struct ScreencastEvent: Hashable, Codable, Sendable {
    /// Time relative to the recording start.
    public var time: CMTime
    /// The kind of interaction.
    public var kind: ScreencastEventKind
    /// Cursor position normalised to 0…1 relative to the captured window/screen bounds, where applicable.
    public var position: CGPoint?
    /// Key code for `.key` events (e.g. virtual key code).
    public var keyCode: UInt16?
    /// Raw modifier flag bits for `.key` events. Stored as `UInt` because
    /// `NSEvent.ModifierFlags` lives in AppKit, which LocalCutCore avoids.
    public var modifierFlagsRaw: UInt?
    /// Whether a key event came from key-down or key-up. Optional so older
    /// event logs decode and fall back to legacy de-duplication.
    public var keyPhase: ScreencastKeyPhase?

    public init(time: CMTime, kind: ScreencastEventKind,
                position: CGPoint? = nil,
                keyCode: UInt16? = nil,
                modifierFlagsRaw: UInt? = nil,
                keyPhase: ScreencastKeyPhase? = nil) {
        self.time = time
        self.kind = kind
        self.position = position
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifierFlagsRaw
        self.keyPhase = keyPhase
    }

    private enum CodingKeys: String, CodingKey {
        case time, kind, position, keyCode, modifierFlagsRaw, keyPhase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        kind = try c.decode(ScreencastEventKind.self, forKey: .kind)
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position)
        keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode)
        modifierFlagsRaw = try c.decodeIfPresent(UInt.self, forKey: .modifierFlagsRaw)
        keyPhase = try c.decodeIfPresent(ScreencastKeyPhase.self, forKey: .keyPhase)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(keyCode, forKey: .keyCode)
        try c.encodeIfPresent(modifierFlagsRaw, forKey: .modifierFlagsRaw)
        try c.encodeIfPresent(keyPhase, forKey: .keyPhase)
    }
}

/// A complete event log captured during an own-app recording session.
public struct ScreencastEventLog: Hashable, Codable, Sendable {
    /// Schema version for forward-compatible persistence.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessionID: UUID
    public var events: [ScreencastEvent]

    public init(schemaVersion: Int = ScreencastEventLog.currentSchemaVersion,
                sessionID: UUID,
                events: [ScreencastEvent]) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.events = events
    }

    /// Returns true if the schema version is supported.
    public var isSupportedSchema: Bool {
        schemaVersion == ScreencastEventLog.currentSchemaVersion
    }
}

// MARK: - Zoom-n-Pan Presets

/// A library preset for zoom/pan animation on a clip's transform.
public enum ZoomPanPresetKind: String, Hashable, Codable, Sendable, CaseIterable {
    /// Gradual zoom into the centre of the frame.
    case slowZoomIn
    /// Horizontal pan across the frame.
    case pan
    /// Quick zoom to a click point, then hold.
    case snapZoomOnClick

    public var displayName: String {
        switch self {
        case .slowZoomIn: "Slow Zoom In"
        case .pan: "Pan"
        case .snapZoomOnClick: "Snap Zoom on Click"
        }
    }
}

/// Parameters for a zoom-n-pan preset applied to a clip.
public struct ZoomPanPreset: Hashable, Codable, Sendable {
    public var kind: ZoomPanPresetKind
    /// Target point in normalised coordinates (0…1) for zoom focus.
    public var targetPoint: CGPoint
    /// Final scale factor relative to the clip's natural size.
    public var endScale: Float
    /// Duration of the animation within the clip.
    public var duration: CMTime

    public init(kind: ZoomPanPresetKind,
                targetPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
                endScale: Float = 1.5,
                duration: CMTime = CMTime(seconds: 3, preferredTimescale: 600)) {
        self.kind = kind
        self.targetPoint = targetPoint
        self.endScale = max(1.0, min(5.0, endScale))
        self.duration = duration.sanitized
    }

    private enum CodingKeys: String, CodingKey {
        case kind, targetPoint, endScale, duration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ZoomPanPresetKind.self, forKey: .kind)
        targetPoint = try c.decode(CGPoint.self, forKey: .targetPoint)
        endScale = try c.decode(Float.self, forKey: .endScale)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .duration)
        duration = timeCode.cmTime
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(targetPoint, forKey: .targetPoint)
        try c.encode(endScale, forKey: .endScale)
        try c.encode(CMTimeCode(duration), forKey: .duration)
    }
}

// MARK: - Zoom-Pan Velocity / Acceleration Bounds

/// Named constants for zoom-pan animation safety bounds.
///
/// These prevent whip-pan and jarring motion by capping how fast and how
/// abruptly the transform can change between keyframes.
public enum ZoomPanBounds: Sendable {
    /// Reference width used to convert normalised transform translations into
    /// render-space points for preset-time bounds enforcement.
    public static let referenceRenderWidth: Float = 1920

    /// Maximum translation velocity in points per second.
    /// At 1920 px width, 600 pt/s feels like a controlled pan; anything
    /// faster reads as a jump cut.
    public static let maxVelocity: Float = 600

    /// Maximum scale change per second (e.g. 0.5 means scale can change by
    /// at most 0.5× per second). Prevents sudden zoom bursts.
    public static let maxScaleVelocity: Float = 0.5

    /// Maximum translation acceleration in points per second². Prevents
    /// abrupt direction reversals.
    public static let maxAcceleration: Float = 1200

    /// Maximum scale acceleration per second².
    public static let maxScaleAcceleration: Float = 1.0
}

// MARK: - Auto-Zoom Proposals

/// A proposed zoom-n-pan action derived from clustering click events in the
/// event log. Each proposal is review-before-apply.
public struct ZoomPanProposal: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID
    /// The time range in the source clip this proposal covers.
    public var timeRange: CMTimeRange
    /// The target centre in normalised coordinates (0…1).
    public var targetPoint: CGPoint
    /// The zoom scale to apply.
    public var endScale: Float
    /// The generated keyframes that would be stamped if applied.
    public var keyframes: [Keyframe<Transform2D>]
    /// Number of click events in the cluster that generated this proposal.
    public var clickCount: Int

    public init(id: UUID = UUID(),
                timeRange: CMTimeRange,
                targetPoint: CGPoint,
                endScale: Float = 2.0,
                keyframes: [Keyframe<Transform2D>],
                clickCount: Int) {
        self.id = id
        self.timeRange = timeRange
        self.targetPoint = targetPoint
        // Clamp endScale to the same range as ZoomPanPreset.
        self.endScale = max(1.0, min(5.0, endScale))
        self.keyframes = keyframes
        self.clickCount = clickCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, timeRangeStart, timeRangeDuration, targetPoint, endScale, keyframes, clickCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let startCode = try c.decode(CMTimeCode.self, forKey: .timeRangeStart)
        let durationCode = try c.decode(CMTimeCode.self, forKey: .timeRangeDuration)
        timeRange = CMTimeRange(start: startCode.cmTime, duration: durationCode.cmTime)
        targetPoint = try c.decode(CGPoint.self, forKey: .targetPoint)
        endScale = max(1.0, min(5.0, try c.decode(Float.self, forKey: .endScale)))
        keyframes = try c.decode([Keyframe<Transform2D>].self, forKey: .keyframes)
        clickCount = try c.decode(Int.self, forKey: .clickCount)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeCode(timeRange.start), forKey: .timeRangeStart)
        try c.encode(CMTimeCode(timeRange.duration), forKey: .timeRangeDuration)
        try c.encode(targetPoint, forKey: .targetPoint)
        try c.encode(endScale, forKey: .endScale)
        try c.encode(keyframes, forKey: .keyframes)
        try c.encode(clickCount, forKey: .clickCount)
    }

    /// Generate a deterministic UUID from proposal content so repeated
    /// generation from the same event log always produces the same ID.
    static func deterministicID(
        timeRange: CMTimeRange,
        targetPoint: CGPoint,
        clickCount: Int
    ) -> UUID {
        var hasher = Hasher()
        hasher.combine(timeRange.start.seconds)
        hasher.combine(timeRange.duration.seconds)
        hasher.combine(targetPoint.x)
        hasher.combine(targetPoint.y)
        hasher.combine(clickCount)
        let hash = hasher.finalize()
        // Construct a UUIDv5-like deterministic UUID from the hash.
        let bytes = withUnsafeBytes(of: hash.bigEndian) { Array($0) }
        // Pad to 16 bytes.
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(bytes.count, 16) { uuidBytes[i] = bytes[i] }
        // Set version 4 bits and variant bits for valid UUID format.
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
    }
}

// MARK: - Callout Kinds

/// The visual style of a callout overlay.
public enum CalloutKind: String, Hashable, Codable, Sendable, CaseIterable {
    case arrow
    case box
    case stepNumber
    case spotlight
    case blurRegion

    public var displayName: String {
        switch self {
        case .arrow: "Arrow"
        case .box: "Box"
        case .stepNumber: "Step Number"
        case .spotlight: "Spotlight"
        case .blurRegion: "Blur Region"
        }
    }
}

/// Style parameters for an arrow callout.
public struct ArrowCalloutStyle: Hashable, Codable, Sendable {
    public var strokeWidth: Float
    public var headLength: Float
    public var headAngle: Float

    public init(strokeWidth: Float = 3, headLength: Float = 20, headAngle: Float = 0.5) {
        self.strokeWidth = max(1, strokeWidth)
        self.headLength = max(5, headLength)
        self.headAngle = max(0.1, min(1.5, headAngle))
    }
}

/// Style parameters for a box callout.
public struct BoxCalloutStyle: Hashable, Codable, Sendable {
    public var strokeWidth: Float
    public var cornerRadius: Float
    public var fillOpacity: Float

    public init(strokeWidth: Float = 3, cornerRadius: Float = 8, fillOpacity: Float = 0) {
        self.strokeWidth = max(1, strokeWidth)
        self.cornerRadius = max(0, cornerRadius)
        self.fillOpacity = max(0, min(1, fillOpacity))
    }
}

/// Style parameters for a step-number callout.
public struct StepNumberCalloutStyle: Hashable, Codable, Sendable {
    public var fontSize: Float
    public var diameter: Float

    public init(fontSize: Float = 24, diameter: Float = 48) {
        self.fontSize = max(12, fontSize)
        self.diameter = max(24, diameter)
    }
}

/// Style parameters for a spotlight callout.
public struct SpotlightCalloutStyle: Hashable, Codable, Sendable {
    /// Radius of the spotlight in normalised coordinates (0…1 relative to frame).
    public var radius: Float
    /// Opacity of the darkened area outside the spotlight (0 = transparent, 1 = black).
    public var dimOpacity: Float
    /// Feather (soft edge) in normalised coordinates.
    public var feather: Float

    public init(radius: Float = 0.15, dimOpacity: Float = 0.7, feather: Float = 0.02) {
        self.radius = max(0.02, min(0.5, radius))
        self.dimOpacity = max(0, min(1, dimOpacity))
        self.feather = max(0, min(0.1, feather))
    }
}

/// Style parameters for a blur-region callout.
public struct BlurRegionCalloutStyle: Hashable, Codable, Sendable {
    /// Blur radius in pixels.
    public var blurRadius: Float
    public var cornerRadius: Float

    public init(blurRadius: Float = 20, cornerRadius: Float = 8) {
        self.blurRadius = max(1, min(100, blurRadius))
        self.cornerRadius = max(0, cornerRadius)
    }
}

// MARK: - Callout Clip

/// A callout element that can be placed on the timeline as a non-destructive
/// overlay. Each callout has a time range, transform, optional keyframed
/// transform animation, and kind-specific style parameters.
public struct CalloutClip: Hashable, Codable, Identifiable, Sendable {
    public let id: UUID
    /// The visual kind of callout.
    public var kind: CalloutKind
    /// Time range in the clip's source time where the callout is visible.
    public var timeRange: CMTimeRange
    /// Static position offset in canvas points.
    public var positionOffset: CGSize
    /// Static scale factor.
    public var scale: Float
    /// Static rotation in radians.
    public var rotation: Float
    /// Optional keyframed transform animation.
    public var transformKeyframes: Keyframed<Transform2D>
    /// The start point for arrow callouts (normalised 0…1).
    public var startPoint: CGPoint
    /// The end point for arrow callouts (normalised 0…1).
    public var endPoint: CGPoint
    /// The bounding rect for box/spotlight/blur callouts (normalised 0…1).
    public var rect: CGRect
    /// The step number for step-number callouts.
    public var stepNumber: Int
    /// Arrow style parameters.
    public var arrowStyle: ArrowCalloutStyle
    /// Box style parameters.
    public var boxStyle: BoxCalloutStyle
    /// Step-number style parameters.
    public var stepNumberStyle: StepNumberCalloutStyle
    /// Spotlight style parameters.
    public var spotlightStyle: SpotlightCalloutStyle
    /// Blur-region style parameters.
    public var blurRegionStyle: BlurRegionCalloutStyle

    public init(id: UUID = UUID(),
                kind: CalloutKind,
                timeRange: CMTimeRange,
                positionOffset: CGSize = .zero,
                scale: Float = 1,
                rotation: Float = 0,
                transformKeyframes: Keyframed<Transform2D> = Keyframed(defaultValue: .identity),
                startPoint: CGPoint = CGPoint(x: 0.3, y: 0.5),
                endPoint: CGPoint = CGPoint(x: 0.7, y: 0.5),
                rect: CGRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                stepNumber: Int = 1,
                arrowStyle: ArrowCalloutStyle = ArrowCalloutStyle(),
                boxStyle: BoxCalloutStyle = BoxCalloutStyle(),
                stepNumberStyle: StepNumberCalloutStyle = StepNumberCalloutStyle(),
                spotlightStyle: SpotlightCalloutStyle = SpotlightCalloutStyle(),
                blurRegionStyle: BlurRegionCalloutStyle = BlurRegionCalloutStyle()) {
        self.id = id
        self.kind = kind
        self.timeRange = timeRange
        self.positionOffset = positionOffset
        // Model allows up to 10× for backward compatibility (older projects
        // may have values between 4 and 10). The inspector UI caps at 4× for
        // usability — values above that are reachable only through presets or
        // manual document editing.
        self.scale = max(0.1, min(10, scale))
        self.rotation = rotation
        self.transformKeyframes = transformKeyframes
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.rect = rect
        self.stepNumber = max(1, stepNumber)
        self.arrowStyle = arrowStyle
        self.boxStyle = boxStyle
        self.stepNumberStyle = stepNumberStyle
        self.spotlightStyle = spotlightStyle
        self.blurRegionStyle = blurRegionStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, timeRangeStart, timeRangeDuration
        case positionOffset, scale, rotation, transformKeyframes
        case startPoint, endPoint, rect, stepNumber
        case arrowStyle, boxStyle, stepNumberStyle, spotlightStyle, blurRegionStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(CalloutKind.self, forKey: .kind)
        let startCode = try c.decode(CMTimeCode.self, forKey: .timeRangeStart)
        let durationCode = try c.decode(CMTimeCode.self, forKey: .timeRangeDuration)
        timeRange = CMTimeRange(start: startCode.cmTime, duration: durationCode.cmTime)
        positionOffset = try c.decode(CGSize.self, forKey: .positionOffset)
        scale = try c.decode(Float.self, forKey: .scale)
        rotation = try c.decode(Float.self, forKey: .rotation)
        transformKeyframes = try c.decode(Keyframed<Transform2D>.self, forKey: .transformKeyframes)
        startPoint = try c.decode(CGPoint.self, forKey: .startPoint)
        endPoint = try c.decode(CGPoint.self, forKey: .endPoint)
        rect = try c.decode(CGRect.self, forKey: .rect)
        stepNumber = try c.decode(Int.self, forKey: .stepNumber)
        arrowStyle = try c.decode(ArrowCalloutStyle.self, forKey: .arrowStyle)
        boxStyle = try c.decode(BoxCalloutStyle.self, forKey: .boxStyle)
        stepNumberStyle = try c.decode(StepNumberCalloutStyle.self, forKey: .stepNumberStyle)
        spotlightStyle = try c.decode(SpotlightCalloutStyle.self, forKey: .spotlightStyle)
        blurRegionStyle = try c.decode(BlurRegionCalloutStyle.self, forKey: .blurRegionStyle)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(CMTimeCode(timeRange.start), forKey: .timeRangeStart)
        try c.encode(CMTimeCode(timeRange.duration), forKey: .timeRangeDuration)
        try c.encode(positionOffset, forKey: .positionOffset)
        try c.encode(scale, forKey: .scale)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(transformKeyframes, forKey: .transformKeyframes)
        try c.encode(startPoint, forKey: .startPoint)
        try c.encode(endPoint, forKey: .endPoint)
        try c.encode(rect, forKey: .rect)
        try c.encode(stepNumber, forKey: .stepNumber)
        try c.encode(arrowStyle, forKey: .arrowStyle)
        try c.encode(boxStyle, forKey: .boxStyle)
        try c.encode(stepNumberStyle, forKey: .stepNumberStyle)
        try c.encode(spotlightStyle, forKey: .spotlightStyle)
        try c.encode(blurRegionStyle, forKey: .blurRegionStyle)
    }

    /// Returns a copy with the step number incremented.
    public func withNextStepNumber() -> CalloutClip {
        var copy = self
        copy.stepNumber = stepNumber + 1
        return copy
    }
}

// MARK: - Padded Background Preset

/// The kind of background rendered behind the inset clip.
public enum PaddedBackgroundSource: String, Hashable, Codable, Sendable {
    /// A solid colour or gradient fill.
    case gradient
    /// An image file referenced by bookmark data.
    case image
}

/// A preset that renders a padded background behind the clip with rounded
/// corners, drop shadow, and an inset margin.
public struct PaddedBackgroundPreset: Hashable, Codable, Sendable {
    public var source: PaddedBackgroundSource
    /// Gradient start colour (RGBA, 0…1). Used when source is `.gradient`.
    public var gradientStart: SIMD4<Float>
    /// Gradient end colour (RGBA, 0…1). Used when source is `.gradient`.
    public var gradientEnd: SIMD4<Float>
    /// Gradient angle in radians.
    public var gradientAngle: Float
    /// Bookmark data for the background image. Used when source is `.image`.
    public var imageBookmark: Data?
    /// Bundle-relative image path (`assets/<uuid>.<ext>`) for portable
    /// `.lcbundle` saves. Runtime paths still resolve through `imageBookmark`.
    public var imageBundleRelativePath: String?
    /// Corner radius of the inset clip frame in points.
    public var cornerRadius: Float
    /// Drop shadow opacity (0…1).
    public var shadowOpacity: Float
    /// Drop shadow radius in points.
    public var shadowRadius: Float
    /// Drop shadow offset.
    public var shadowOffset: CGSize
    /// Inset margin in points.
    public var insetMargin: Float

    public init(source: PaddedBackgroundSource = .gradient,
                gradientStart: SIMD4<Float> = SIMD4(0.15, 0.15, 0.2, 1),
                gradientEnd: SIMD4<Float> = SIMD4(0.08, 0.08, 0.12, 1),
                gradientAngle: Float = .pi / 2,
                imageBookmark: Data? = nil,
                imageBundleRelativePath: String? = nil,
                cornerRadius: Float = 16,
                shadowOpacity: Float = 0.5,
                shadowRadius: Float = 20,
                shadowOffset: CGSize = CGSize(width: 0, height: -4),
                insetMargin: Float = 40) {
        self.source = source
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.gradientAngle = gradientAngle
        self.imageBookmark = imageBookmark
        self.imageBundleRelativePath = imageBundleRelativePath
        self.cornerRadius = max(0, cornerRadius)
        self.shadowOpacity = max(0, min(1, shadowOpacity))
        self.shadowRadius = max(0, shadowRadius)
        self.shadowOffset = shadowOffset
        self.insetMargin = max(0, insetMargin)
    }
}
