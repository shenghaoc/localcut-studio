import Foundation

// MARK: - Versioned preset envelope

public struct CaptionPresetV1: Codable, Equatable, Sendable {
    public var version: String = "1"
    public var name: String
    public var family: String
    public var style: CaptionStyle

    public init(version: String = "1", name: String, family: String, style: CaptionStyle) {
        self.version = version
        self.name = name
        self.family = family
        self.style = style
    }
}

// MARK: - Built-in library

public enum BuiltInCaptionPresets: Sendable {

    public static let all: [CaptionPresetV1] = [
        socialBoldYellow,
        socialPopWhite,
        socialNeon,
        newsLowerThird,
        explainerBlackBar,
        cinematicSerif,
        cinematicCenter,
        karaokeBounce,
        karaokeTypewriter,
        retroOutline,
        tutorialScreencast,
    ]

    public static let socialBoldYellow = CaptionPresetV1(
        name: "TikTok Bold Yellow",
        family: "social",
        style: {
            var s = CaptionStyle()
            s.fontName = "Helvetica-Bold"
            s.fontSize = 96
            s.fill = .white
            s.stroke = StrokeStyle(colour: .black, width: 8)
            s.shadow = ShadowStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 0.6),
                                   offsetX: 0, offsetY: -4, blur: 6)
            s.anchor = .bottom
            s.verticalInset = 160
            s.wordHighlightFill = .yellow
            s.enterAnimation = .pop
            s.enterDuration = 0.15
            s.exitAnimation = .fade
            s.exitDuration = 0.2
            return s
        }())

    public static let socialPopWhite = CaptionPresetV1(
        name: "Pop White",
        family: "social",
        style: {
            var s = CaptionStyle()
            s.fontName = "Helvetica-Bold"
            s.fontSize = 82
            s.fill = .white
            s.shadow = ShadowStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 0.45),
                                   offsetX: 0, offsetY: -3, blur: 8)
            s.anchor = .bottom
            s.verticalInset = 200
            s.enterAnimation = .pop
            s.enterDuration = 0.2
            return s
        }())

    public static let socialNeon = CaptionPresetV1(
        name: "Neon Glow",
        family: "social",
        style: {
            var s = CaptionStyle()
            s.fontName = "Helvetica-Bold"
            s.fontSize = 88
            s.fill = .white
            s.glow = GlowStyle(colour: RGBAColour(red: 0.4, green: 0.9, blue: 1, alpha: 1), radius: 24)
            s.anchor = .middle
            s.enterAnimation = .pop
            s.enterDuration = 0.25
            return s
        }())

    public static let newsLowerThird = CaptionPresetV1(
        name: "News Lower Third",
        family: "news",
        style: {
            var s = CaptionStyle()
            s.fontName = "Helvetica"
            s.fontSize = 56
            s.fill = .white
            s.pill = PillStyle(colour: RGBAColour(red: 0.13, green: 0.16, blue: 0.32, alpha: 0.9),
                               cornerRadius: 6, paddingX: 24, paddingY: 14)
            s.anchor = .bottom
            s.verticalInset = 96
            s.enterAnimation = .slide
            s.slideDirection = .fromLeft
            s.enterDuration = 0.3
            s.exitAnimation = .slide
            s.exitDuration = 0.25
            return s
        }())

    public static let explainerBlackBar = CaptionPresetV1(
        name: "Explainer Black Bar",
        family: "news",
        style: {
            var s = CaptionStyle()
            s.fontName = "Helvetica"
            s.fontSize = 60
            s.fill = .white
            s.pill = PillStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 0.7),
                               cornerRadius: 0, paddingX: 32, paddingY: 18)
            s.anchor = .bottom
            s.verticalInset = 60
            s.enterAnimation = .none
            s.exitAnimation = .fade
            s.exitDuration = 0.15
            return s
        }())

    public static let cinematicSerif = CaptionPresetV1(
        name: "Cinematic Serif",
        family: "cinematic",
        style: {
            var s = CaptionStyle()
            s.fontName = "Times-Italic"
            s.fontSize = 64
            s.fill = RGBAColour(red: 0.96, green: 0.93, blue: 0.84)
            s.shadow = ShadowStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 0.6),
                                   offsetX: 0, offsetY: -2, blur: 12)
            s.anchor = .bottom
            s.verticalInset = 144
            s.enterAnimation = .none
            s.exitAnimation = .fade
            s.exitDuration = 0.4
            return s
        }())

    public static let cinematicCenter = CaptionPresetV1(
        name: "Cinematic Centre",
        family: "cinematic",
        style: {
            var s = CaptionStyle()
            s.fontName = "Georgia"
            s.fontSize = 72
            s.fill = .white
            s.letterSpacing = 4
            s.anchor = .middle
            s.enterAnimation = .none
            s.exitAnimation = .fade
            s.exitDuration = 0.5
            return s
        }())

    public static let karaokeBounce = CaptionPresetV1(
        name: "Karaoke Bounce",
        family: "karaoke",
        style: {
            var s = CaptionStyle()
            s.fontName = "Helvetica-Bold"
            s.fontSize = 86
            s.fill = .white
            s.stroke = StrokeStyle(colour: .black, width: 6)
            s.wordHighlightFill = RGBAColour(red: 1, green: 0.85, blue: 0.2)
            s.anchor = .middle
            s.enterAnimation = .bounce
            s.enterDuration = 0.35
            s.exitAnimation = .pop
            s.exitDuration = 0.2
            return s
        }())

    public static let karaokeTypewriter = CaptionPresetV1(
        name: "Karaoke Typewriter",
        family: "karaoke",
        style: {
            var s = CaptionStyle()
            s.fontName = "Courier-Bold"
            s.fontSize = 72
            s.fill = .white
            s.stroke = StrokeStyle(colour: .black, width: 4)
            s.anchor = .bottom
            s.verticalInset = 140
            s.enterAnimation = .typewriter
            s.enterDuration = 0.6
            s.exitAnimation = .fade
            s.exitDuration = 0.2
            return s
        }())

    public static let retroOutline = CaptionPresetV1(
        name: "Retro Outline",
        family: "retro",
        style: {
            var s = CaptionStyle()
            s.fontName = "Helvetica-Bold"
            s.fontSize = 88
            s.fill = RGBAColour(red: 1, green: 0.92, blue: 0.36)
            s.stroke = StrokeStyle(colour: RGBAColour(red: 0.69, green: 0.13, blue: 0.27), width: 10)
            s.shadow = ShadowStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 0.45),
                                   offsetX: 0, offsetY: -6, blur: 10)
            s.anchor = .bottom
            s.verticalInset = 160
            s.enterAnimation = .slide
            s.slideDirection = .fromBottom
            s.enterDuration = 0.3
            return s
        }())

    // MARK: - Tutorial / Screencast

    /// A caption preset tuned for tutorials and screencasts: sans-serif,
    /// high-contrast white on a dark pill background, larger readable font,
    /// no animation.
    public static let tutorialScreencast = CaptionPresetV1(
        name: "Tutorial",
        family: "tutorial",
        style: {
            var s = CaptionStyle()
            s.fontName = "Helvetica"
            s.fontSize = 52
            s.fill = .white
            s.pill = PillStyle(
                colour: RGBAColour(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.92),
                cornerRadius: 10,
                paddingX: 20,
                paddingY: 10)
            s.anchor = .bottom
            s.verticalInset = 80
            s.enterAnimation = .none
            s.exitAnimation = .none
            return s
        }())
}

// MARK: - .lccaption I/O

public enum CaptionPresetIO: Sendable {
    public enum IOError: Error, LocalizedError, Sendable {
        case unsupportedVersion(String)
        case decodeFailed(underlyingError: String?)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                "Preset format version \(v) isn't supported by this build."
            case .decodeFailed(let detail):
                if let detail, !detail.isEmpty {
                    "The preset file isn't valid JSON: \(detail)"
                } else {
                    "The preset file isn't valid JSON."
                }
            }
        }
    }

    public static let fileExtension = "lccaption"

    public static func encode(_ preset: CaptionPresetV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(preset)
    }

    public static func decode(_ data: Data) throws -> CaptionPresetV1 {
        let preset: CaptionPresetV1
        do {
            preset = try JSONDecoder().decode(CaptionPresetV1.self, from: data)
        } catch {
            throw IOError.decodeFailed(underlyingError: error.localizedDescription)
        }
        guard preset.version == "1" else {
            throw IOError.unsupportedVersion(preset.version)
        }
        return preset
    }

    public static func read(from url: URL) throws -> CaptionPresetV1 {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func write(_ preset: CaptionPresetV1, to url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try encode(preset)
        try data.write(to: url, options: .atomic)
    }
}
