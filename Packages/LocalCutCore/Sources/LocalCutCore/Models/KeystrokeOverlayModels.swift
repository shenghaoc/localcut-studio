import Foundation
import CoreMedia
import CoreGraphics

// MARK: - Keystroke Display Mode

/// How a keystroke event is rendered on the overlay.
public enum KeystrokeDisplayMode: String, Hashable, Codable, Sendable {
    /// A single character key (e.g. "A", "5", ".").
    case character
    /// A modifier key rendered as a chip (e.g. "⌘", "⇧", "⌥", "⌃").
    case modifier
    /// A function or special key rendered as a label (e.g. "Return", "Tab", "Space").
    case special
}

// MARK: - Keystroke Overlay Event

/// A single keystroke event prepared for overlay rendering. Derived from
/// `ScreencastEvent` entries of kind `.key`.
public struct KeystrokeOverlayEvent: Hashable, Identifiable, Sendable {
    public let id: UUID
    /// When the keystroke appears on the timeline.
    public var time: CMTime
    /// The display text for this keystroke (e.g. "⌘", "A", "Return").
    public var displayText: String
    /// How this keystroke should be rendered.
    public var displayMode: KeystrokeDisplayMode

    public init(id: UUID = UUID(), time: CMTime,
                displayText: String, displayMode: KeystrokeDisplayMode) {
        self.id = id
        self.time = time
        self.displayText = displayText
        self.displayMode = displayMode
    }
}

extension KeystrokeOverlayEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, time, displayText, displayMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        displayText = try c.decode(String.self, forKey: .displayText)
        displayMode = try c.decode(KeystrokeDisplayMode.self, forKey: .displayMode)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(displayText, forKey: .displayText)
        try c.encode(displayMode, forKey: .displayMode)
    }
}

// MARK: - Keystroke Overlay Style

/// Style parameters for the keystroke overlay.
public struct KeystrokeOverlayStyle: Hashable, Codable, Sendable {
    /// Font name for keystroke text.
    public var fontName: String
    /// Font size in points.
    public var fontSize: Float
    /// Normalised Y position (0 = top, 1 = bottom). Default near bottom.
    public var normalizedY: Float
    /// Normalised X position (0 = left, 1 = right). Default centre.
    public var normalizedX: Float
    /// Fade-in duration per keystroke in seconds.
    public var fadeInDuration: Float
    /// Fade-out duration per keystroke in seconds.
    public var fadeOutDuration: Float
    /// How long each keystroke remains visible before fading out.
    public var holdDuration: Float
    /// Background pill corner radius.
    public var pillCornerRadius: Float
    /// Background pill horizontal padding.
    public var pillPaddingX: Float
    /// Background pill vertical padding.
    public var pillPaddingY: Float

    public init(fontName: String = "SF Mono",
                fontSize: Float = 36,
                normalizedY: Float = 0.85,
                normalizedX: Float = 0.5,
                fadeInDuration: Float = 0.1,
                fadeOutDuration: Float = 0.15,
                holdDuration: Float = 1.0,
                pillCornerRadius: Float = 8,
                pillPaddingX: Float = 12,
                pillPaddingY: Float = 6) {
        self.fontName = fontName
        self.fontSize = max(12, fontSize)
        self.normalizedY = max(0, min(1, normalizedY))
        self.normalizedX = max(0, min(1, normalizedX))
        self.fadeInDuration = max(0, fadeInDuration)
        self.fadeOutDuration = max(0, fadeOutDuration)
        self.holdDuration = max(0, holdDuration)
        self.pillCornerRadius = max(0, pillCornerRadius)
        self.pillPaddingX = max(0, pillPaddingX)
        self.pillPaddingY = max(0, pillPaddingY)
    }
}

// MARK: - Keystroke Overlay Clip

/// A timeline clip that renders keystroke events from a Phase 43 event log.
/// This is a virtual clip — it does not hold media but drives overlay rendering.
public struct KeystrokeOverlayClip: Hashable, Identifiable, Sendable {
    public let id: UUID
    /// The session ID of the source event log.
    public var sourceSessionID: UUID
    /// The time range on the timeline this overlay covers.
    public var timeRange: CMTimeRange
    /// The events to render, derived from the event log.
    public var events: [KeystrokeOverlayEvent]
    /// Style parameters.
    public var style: KeystrokeOverlayStyle
    /// Opacity of the overlay (0…1).
    public var opacity: Float

    public init(id: UUID = UUID(),
                sourceSessionID: UUID,
                timeRange: CMTimeRange,
                events: [KeystrokeOverlayEvent] = [],
                style: KeystrokeOverlayStyle = KeystrokeOverlayStyle(),
                opacity: Float = 1) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.timeRange = timeRange
        self.events = events
        self.style = style
        self.opacity = max(0, min(1, opacity))
    }
}

extension KeystrokeOverlayClip: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourceSessionID, timeRangeStart, timeRangeDuration
        case events, style, opacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceSessionID = try c.decode(UUID.self, forKey: .sourceSessionID)
        let startCode = try c.decode(CMTimeCode.self, forKey: .timeRangeStart)
        let durationCode = try c.decode(CMTimeCode.self, forKey: .timeRangeDuration)
        timeRange = CMTimeRange(start: startCode.cmTime, duration: durationCode.cmTime)
        events = try c.decodeIfPresent([KeystrokeOverlayEvent].self, forKey: .events) ?? []
        style = try c.decodeIfPresent(KeystrokeOverlayStyle.self, forKey: .style) ?? KeystrokeOverlayStyle()
        opacity = try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceSessionID, forKey: .sourceSessionID)
        try c.encode(CMTimeCode(timeRange.start), forKey: .timeRangeStart)
        try c.encode(CMTimeCode(timeRange.duration), forKey: .timeRangeDuration)
        try c.encode(events, forKey: .events)
        try c.encode(style, forKey: .style)
        try c.encode(opacity, forKey: .opacity)
    }
}
