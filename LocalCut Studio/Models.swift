import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

// MARK: - Working colour space

/// The project's working colour space. Tags the compositor's `CIContext`
/// `workingColorSpace` and every output `CVPixelBuffer` so downstream
/// `AVAssetExportSession` / `AVAssetWriter` carry it through.
///
/// sRGB is the default and the path all v1 grading was tuned against; the
/// wider-gamut spaces are configurable for advanced finishing but not yet
/// validated against a calibrated reference (see [design](../../.kiro/specs/feature-colour-management/design.md#risks)).
nonisolated enum WorkingColourSpace: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case sRGB
    case displayP3
    case rec709
    case rec2020

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .rec709: "Rec. 709"
        case .rec2020: "Rec. 2020"
        }
    }

    /// `CGColorSpace` used as the `CIContext.workingColorSpace` and the
    /// render-time `colorSpace` argument.
    var cgColorSpace: CGColorSpace {
        let name: CFString
        switch self {
        case .sRGB: name = CGColorSpace.sRGB
        case .displayP3: name = CGColorSpace.displayP3
        case .rec709: name = CGColorSpace.itur_709
        case .rec2020: name = CGColorSpace.itur_2020
        }
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Value for the `kCVImageBufferColorPrimariesKey` attachment.
    var cvColorPrimaries: CFString {
        switch self {
        case .sRGB, .rec709: kCVImageBufferColorPrimaries_ITU_R_709_2
        case .displayP3: kCVImageBufferColorPrimaries_P3_D65
        case .rec2020: kCVImageBufferColorPrimaries_ITU_R_2020
        }
    }

    /// Value for the `kCVImageBufferTransferFunctionKey` attachment. Display P3
    /// uses the sRGB transfer (the IEC 61966-2-1 piecewise curve), matching
    /// what `CGColorSpace.displayP3` declares. Rec.2020 here is **SDR Rec.2020
    /// only** — the practical SDR delivery transfer is BT.709/BT.1886, not
    /// the little-used `ITU_R_2020` constant (which AVFoundation doesn't
    /// round-trip cleanly on output buffer attachments in our pipeline). HDR
    /// (PQ / HLG) is out of scope for v1.
    var cvTransferFunction: CFString {
        switch self {
        case .sRGB, .displayP3: kCVImageBufferTransferFunction_sRGB
        case .rec709, .rec2020: kCVImageBufferTransferFunction_ITU_R_709_2
        }
    }

    /// Value for the `kCVImageBufferYCbCrMatrixKey` attachment. SDR Rec.2020
    /// uses the BT.709 YCbCr matrix here (constant-luminance Rec.2020 with
    /// its own matrix is out of scope for v1); only the primaries differ.
    var cvYCbCrMatrix: CFString {
        switch self {
        case .sRGB, .displayP3, .rec709, .rec2020: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }
}

// MARK: - Metadata Sanitization

extension CMTime {
    /// A generous upper bound (in seconds) for a trusted media duration. Values
    /// beyond this are treated as corrupt: they serve no legitimate editing
    /// purpose and would later trap `Int(seconds)` in timecode formatting.
    nonisolated private static let maxSaneSeconds: Double = 100 * 60 * 60   // 100 hours

    /// Returns a validated time, falling back to `.zero` if the time is invalid,
    /// indefinite, infinite, negative, or implausibly large (any of which could
    /// corrupt geometry/time math or trap downstream timecode conversion).
    ///
    /// Negativity is checked with `self >= .zero` rather than `value >= 0` so a
    /// negative `timescale` (possible in corrupted files) can't slip a negative
    /// time through.
    nonisolated var sanitized: CMTime {
        guard isValid, !isIndefinite, !isPositiveInfinity, !isNegativeInfinity,
              self >= .zero, seconds.isFinite, seconds <= CMTime.maxSaneSeconds else {
            return .zero
        }
        return self
    }
}

extension CGSize {
    /// Upper bound (in pixels) for a plausible media dimension. Beyond this,
    /// values are treated as corrupt — they exceed any real frame size and would
    /// trap `Int(...)` when the inspector formats the dimensions.
    nonisolated private static let maxSanePixels: CGFloat = 100_000   // well past 8K

    /// Returns a validated size, falling back to `.zero` if non-finite, and
    /// clamping each dimension into `0...maxSanePixels`.
    nonisolated var sanitized: CGSize {
        guard width.isFinite, height.isFinite else { return .zero }
        func clamp(_ v: CGFloat) -> CGFloat { min(max(0, v), CGSize.maxSanePixels) }
        return CGSize(width: clamp(width), height: clamp(height))
    }
}

extension CGAffineTransform {
    /// Upper bound on the magnitude of any transform coefficient. Beyond this,
    /// applying the matrix to a natural size can overflow the oriented bounds to
    /// infinity and produce `inf * 0` / NaN translations during frame fitting.
    nonisolated private static let maxSaneCoefficient: CGFloat = 1_000_000

    /// Returns a validated transform, falling back to `.identity` if any
    /// component is non-finite or implausibly large.
    nonisolated var sanitized: CGAffineTransform {
        func ok(_ v: CGFloat) -> Bool { v.isFinite && abs(v) <= CGAffineTransform.maxSaneCoefficient }
        guard ok(a), ok(b), ok(c), ok(d), ok(tx), ok(ty) else { return .identity }
        return self
    }
}

// MARK: - Media

/// A source media file imported into the project's media bin.
///
/// Backed by an `AVURLAsset`. Metadata (duration, natural size, orientation) is
/// loaded asynchronously at import time so the rest of the app can treat it as
/// readily available, mirroring the role of a decoded media handle in the
/// browser original.
@Observable
final class MediaItem: Identifiable {
    let id: UUID
    let url: URL
    let asset: AVURLAsset

    var name: String
    var duration: CMTime = .zero
    var naturalSize: CGSize = .zero
    var preferredTransform: CGAffineTransform = .identity
    var hasVideo = false
    var hasAudio = false

    /// Security-scoped bookmark to `url`, created at import. Persisted in the
    /// project document so the file can be re-resolved across launches under the
    /// sandbox (R1.2). `nil` until a bookmark could be created, or for media that
    /// lives inside the project bundle (the bundle's outer URL is the grant).
    var bookmark: Data?

    /// Bundle-relative path (`assets/<id>.<ext>`) when this media has been
    /// copied into the current `.lcbundle` project. `nil` for media that has
    /// not been placed in a bundle yet (legacy `.lcstudio` documents) or that
    /// the user has explicitly opted out of bundling (see `wantsBundling`).
    var bundleRelativePath: String?

    /// Whether this media should be **copied into** the bundle on the next
    /// bundle save. Defaults to `true` — the standard "include media in the
    /// project" expectation. A future "Don't copy" import option flips this
    /// to `false`, which the bundle save path then honours by leaving the
    /// ref external (bookmark-resolved) instead of stamping a bundled path.
    var wantsBundling: Bool = true

    /// Poster frame shown in the media bin. Generated lazily after import.
    var thumbnail: CGImage?

    init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.name = url.deletingPathExtension().lastPathComponent
    }

    var durationSeconds: Double { duration.seconds.isFinite ? duration.seconds : 0 }

    /// Generates the poster frame from near the asset's start. Lives on the media
    /// item (not the editor) so a background decode task retains only this object,
    /// never the whole `EditorModel`.
    func loadThumbnail() async {
        guard hasVideo else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let time = CMTime(seconds: min(0.1, durationSeconds / 2), preferredTimescale: 600)
        if let result = try? await generator.image(at: time) {
            thumbnail = result.image
        }
    }
}

// MARK: - Timeline

enum TrackKind: Hashable {
    case video
    case audio
}

// MARK: - Colour Grading

/// Perceptual colour-adjustment parameters with neutral defaults and clamping.
nonisolated struct ColourGrade: Hashable, Codable, Sendable {
    var exposure: Float = 0        // CIExposureAdjust.inputEV, range [-2, 2]
    var contrast: Float = 1        // CIColorControls.inputContrast, range [0.5, 1.5]
    var saturation: Float = 1      // CIColorControls.inputSaturation, range [0, 2]
    var temperatureOffset: Float = 0  // CITemperatureAndTint offset from 6500K, range [-4000, 4000]
    var tintOffset: Float = 0         // CITemperatureAndTint offset from 0, range [-150, 150]

    static let neutral = ColourGrade()

    mutating func clamp() {
        exposure = max(-2, min(2, exposure))
        contrast = max(0.5, min(1.5, contrast))
        saturation = max(0, min(2, saturation))
        temperatureOffset = max(-4000, min(4000, temperatureOffset))
        tintOffset = max(-150, min(150, tintOffset))
    }
}

/// Skin smoothing parameters with neutral defaults and clamping.
nonisolated struct SkinSmoothEffect: Hashable, Codable, Sendable {
    /// Overall smoothing strength (0 = off, 1 = maximum).
    var strength: Keyframed<Float>
    /// Bias for the skin-tone probability mask (positive = more inclusive).
    var maskWarmthBias: Float = 0
    /// Luminance gate for the mask (0 = all luminances, 1 = only mid-tones).
    var maskLuminanceGate: Float = 0.1
    /// When true, bypass the effect for A/B comparison.
    var bypass: Bool = false

    init() {
        self.strength = Keyframed<Float>(defaultValue: 0)
    }

    static var neutral: SkinSmoothEffect { SkinSmoothEffect() }

    mutating func clamp() {
        // Clamp static parameters
        maskWarmthBias = max(-1, min(1, maskWarmthBias))
        maskLuminanceGate = max(0, min(1, maskLuminanceGate))
        // Clamp keyframe values and default value efficiently
        let clampedKeyframes = strength.keyframes.map { kf in
            Keyframe(id: kf.id, time: kf.time, value: max(0, min(1, kf.value)))
        }
        let clampedDefault = max(0, min(1, strength.defaultValue))
        strength = Keyframed<Float>(keyframes: clampedKeyframes, defaultValue: clampedDefault)
    }
}

/// An effect that can be applied to a video clip's source frames.
enum Effect: Hashable, Codable {
    case colourGrade(ColourGrade)
    case lut(bookmark: Data)
    case skinSmooth(SkinSmoothEffect)

    static func == (lhs: Effect, rhs: Effect) -> Bool {
        switch (lhs, rhs) {
        case (.colourGrade(let a), .colourGrade(let b)): a == b
        case (.lut(bookmark: let a), .lut(bookmark: let b)): a == b
        case (.skinSmooth(let a), .skinSmooth(let b)): a == b
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .colourGrade(let g): hasher.combine(0); hasher.combine(g)
        case .lut(bookmark: let d): hasher.combine(1); hasher.combine(d)
        case .skinSmooth(let s): hasher.combine(2); hasher.combine(s)
        }
    }
}

// MARK: - Transitions

/// The kinds of transition supported in v1.
enum TransitionType: String, Hashable, Codable, CaseIterable, Identifiable {
    /// A linear opacity cross-fade between the outgoing and incoming clips.
    case crossDissolve
    /// A directional bars-swipe handled by the custom compositor.
    case wipe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crossDissolve: "Cross Dissolve"
        case .wipe: "Wipe"
        }
    }

    /// SF Symbol used for the timeline glyph and inspector.
    var symbolName: String {
        switch self {
        case .crossDissolve: "circle.lefthalf.filled"
        case .wipe: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        }
    }
}

/// A transition placed at the cut where its owning (trailing) clip meets the
/// immediately-preceding adjacent clip on the same video track.
///
/// `duration` is the *requested* length; the actually-rendered overlap is
/// derived at build time and clamped to the available length of the two
/// neighbouring clips (see `TransitionLayout`). The overlap is never stored on
/// the clips themselves — adjacent clips stay butt-joined in authored time.
struct Transition: Identifiable, Hashable {
    let id: UUID
    var type: TransitionType
    var duration: CMTime

    init(id: UUID = UUID(), type: TransitionType = .crossDissolve, duration: CMTime) {
        self.id = id
        self.type = type
        self.duration = duration
    }

    /// Sensible default transition length (0.5s, R4.2), clamped to overlap when applied.
    static let defaultDuration = CMTime(value: 1, timescale: 2)
}

/// A single placement of (part of) a media item on a track's timeline.
struct Clip: Identifiable, Hashable {
    let id = UUID()
    var mediaID: MediaItem.ID

    /// In-point within the source media.
    var sourceStart: CMTime
    /// How much of the source plays on the timeline.
    var duration: CMTime
    /// Where the clip begins on the track's timeline.
    var timelineStart: CMTime

    /// Per-clip opacity used when compositing video layers (0...1).
    var opacity: Float = 1

    /// Ordered effect chain applied to every source frame of this clip.
    var effects: [Effect] = []

    /// A transition into this clip from the preceding adjacent clip, if any.
    /// The trailing clip owns the transition; the overlap is derived, not stored.
    var transition: Transition?

    /// Per-clip audio volume envelope (P16). Extends — does not replace — the
    /// transition crossfade ramps written by `CompositionBuilder`; an empty
    /// envelope is bit-identical to the pre-bus behaviour. Audio-only data;
    /// stored on video clips too so the model stays kind-agnostic, but unused
    /// for video pieces (audio mix params are only built for audio tracks).
    var volumeEnvelope: VolumeEnvelope = VolumeEnvelope()

    var timelineEnd: CMTime { timelineStart + duration }

    var timeRangeInSource: CMTimeRange { CMTimeRange(start: sourceStart, duration: duration) }
}

/// An ordered lane of clips of a single kind.
@Observable
final class Track: Identifiable {
    /// `let` so identity stays stable for the runtime lifetime of the track.
    /// Document load passes the persisted UUID so audio-bus inputs keyed by
    /// `Track.id` keep matching after open (otherwise gain/pan saved against
    /// the old runtime UUID would be silently ignored).
    let id: UUID
    var name: String
    let kind: TrackKind
    var clips: [Clip] = []
    var isMuted = false

    init(id: UUID = UUID(), name: String, kind: TrackKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// The first free time at the tail of the track, used for ripple-append.
    var endTime: CMTime {
        clips.reduce(.zero) { CMTimeMaximum($0, $1.timelineEnd) }
    }
}

// MARK: - Keyframes

/// A type that can be linearly interpolated between two values.
nonisolated protocol Interpolatable: Hashable, Codable, Sendable {
    static func lerp(_ a: Self, _ b: Self, t: Float) -> Self
}

extension Float: Interpolatable {
    nonisolated static func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }
}

/// A single point in time with an associated value.
nonisolated struct Keyframe<T: Interpolatable>: Hashable, Codable, Identifiable, Sendable {
    let id: UUID
    var time: CMTime
    var value: T

    init(id: UUID = UUID(), time: CMTime, value: T) {
        self.id = id
        self.time = time
        self.value = value
    }

    /// Codable shape nests `time` as a `CMTimeCode`-shaped object (`{value,
    /// timescale}`) so the document representation matches the rest of the project
    /// and the kf's `value` key doesn't collide with the time-rational's.
    private enum CodingKeys: String, CodingKey { case id, time, value }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        value = try c.decode(T.self, forKey: .value)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(value, forKey: .value)
    }
}

/// A sorted collection of keyframes that interpolates linearly between them.
///
/// Empty → `defaultValue` for every time. Single keyframe → its value
/// everywhere. Multiple keyframes → clamped at the edges, lerp in between.
nonisolated struct Keyframed<T: Interpolatable>: Hashable, Codable, Sendable {
    private(set) var keyframes: [Keyframe<T>]
    var defaultValue: T

    init(defaultValue: T) {
        self.keyframes = []
        self.defaultValue = defaultValue
    }

    init(keyframes: [Keyframe<T>], defaultValue: T) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey { case keyframes, defaultValue }

    /// Explicit decoder so a hand-edited or migrated document with unsorted
    /// keyframes still produces sorted state — the synthesised decoder would
    /// assign the raw array verbatim and break `value(at:)`'s binary search.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([Keyframe<T>].self, forKey: .keyframes)
        let dv = try c.decode(T.self, forKey: .defaultValue)
        self.init(keyframes: raw, defaultValue: dv)
    }

    var isAnimated: Bool { !keyframes.isEmpty }

    /// Linearly interpolates between the two surrounding keyframes.
    /// O(log n) via binary search for the lower bound.
    func value(at time: CMTime) -> T {
        guard let first = keyframes.first, let last = keyframes.last else { return defaultValue }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }

        var lo = 0
        var hi = keyframes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keyframes[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        let before = keyframes[lo]
        let after = keyframes[lo + 1]
        let elapsed = (time - before.time).seconds
        let span = (after.time - before.time).seconds
        guard span > 0 else { return before.value }
        let t = Float(elapsed / span)
        return T.lerp(before.value, after.value, t: min(1, max(0, t)))
    }

    mutating func addKeyframe(at time: CMTime, value: T) {
        let kf = Keyframe(time: time, value: value)
        if let i = keyframes.firstIndex(where: { $0.time >= time }) {
            if keyframes[i].time == time {
                keyframes[i] = kf
            } else {
                keyframes.insert(kf, at: i)
            }
        } else {
            keyframes.append(kf)
        }
    }

    mutating func removeKeyframe(id: UUID) {
        keyframes.removeAll { $0.id == id }
    }

    mutating func updateKeyframe(id: UUID, time: CMTime? = nil, value: T? = nil) {
        guard let i = keyframes.firstIndex(where: { $0.id == id }) else { return }
        // If a new time is set and another keyframe already sits exactly there,
        // drop the collider so the array preserves the single-keyframe-per-time
        // invariant `addKeyframe` enforces. Without this, `value(at:)`'s binary
        // search returns the first hit in the ambiguous zone.
        if let time {
            keyframes.removeAll { $0.id != id && $0.time == time }
        }
        // The just-updated keyframe may have moved during the removal above.
        guard let j = keyframes.firstIndex(where: { $0.id == id }) else { return }
        if let time { keyframes[j].time = time }
        if let value { keyframes[j].value = value }
        keyframes.sort { $0.time < $1.time }
    }
}

// MARK: - Caption Style (Phase 30)

/// An sRGB colour stored as four floats so it round-trips through Codable and
/// stays `Sendable`. The compositor reads it through `cgColor`.
nonisolated struct RGBAColour: Hashable, Codable, Sendable, Interpolatable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let white = RGBAColour(red: 1, green: 1, blue: 1)
    static let black = RGBAColour(red: 0, green: 0, blue: 0)
    static let clear = RGBAColour(red: 0, green: 0, blue: 0, alpha: 0)
    static let yellow = RGBAColour(red: 1, green: 0.85, blue: 0.2)

    var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)])
            ?? CGColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    nonisolated static func lerp(_ a: RGBAColour, _ b: RGBAColour, t: Float) -> RGBAColour {
        RGBAColour(
            red: Float.lerp(a.red, b.red, t: t),
            green: Float.lerp(a.green, b.green, t: t),
            blue: Float.lerp(a.blue, b.blue, t: t),
            alpha: Float.lerp(a.alpha, b.alpha, t: t))
    }
}

/// Outline drawn around each glyph; width = 0 disables.
nonisolated struct StrokeStyle: Hashable, Codable, Sendable {
    var colour: RGBAColour = .black
    var width: Float = 0
}

/// Drop shadow under the line; `radius` = 0 disables.
nonisolated struct ShadowStyle: Hashable, Codable, Sendable {
    var colour: RGBAColour = RGBAColour(red: 0, green: 0, blue: 0, alpha: 0.5)
    var offsetX: Float = 0
    var offsetY: Float = -2
    var blur: Float = 4
    var radius: Float { blur }
}

/// Soft glow behind glyphs; `radius` = 0 disables.
nonisolated struct GlowStyle: Hashable, Codable, Sendable {
    var colour: RGBAColour = .clear
    var radius: Float = 0
}

/// Rounded background pill drawn behind the line; `alpha == 0` disables.
nonisolated struct PillStyle: Hashable, Codable, Sendable {
    var colour: RGBAColour = .clear
    var cornerRadius: Float = 12
    var paddingX: Float = 16
    var paddingY: Float = 8
}

/// Enter animation kinds Phase 30 ships.
nonisolated enum CaptionEnterAnimation: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case none, pop, bounce, slide, typewriter
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: "None"
        case .pop: "Pop"
        case .bounce: "Bounce"
        case .slide: "Slide"
        case .typewriter: "Typewriter"
        }
    }
}

/// Exit animation kinds Phase 30 ships — currently the mirror of enter.
nonisolated enum CaptionExitAnimation: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case none, pop, slide, fade
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: "None"
        case .pop: "Pop"
        case .slide: "Slide"
        case .fade: "Fade"
        }
    }
}

/// Direction parameter for `slide` enter and exit animations.
nonisolated enum SlideDirection: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case fromBottom, fromTop, fromLeft, fromRight
    var id: String { rawValue }
}

/// Where on the render canvas a line sits, vertically. Horizontal is always centred.
nonisolated enum CaptionAnchor: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case top, middle, bottom
    var id: String { rawValue }
}

/// The full set of caption styling parameters Phase 30 exposes. Every parameter
/// has a documented default; missing values fall back to track defaults, then to
/// `CaptionStyle.identity`.
nonisolated struct CaptionStyle: Hashable, Codable, Sendable {
    /// PostScript name. The weight is encoded by the name itself (e.g.
    /// `Helvetica-Bold` vs `Helvetica`); there is no separate weight knob
    /// because `CTFontCreateWithName` doesn't take one.
    var fontName: String = "Helvetica-Bold"
    var fontSize: Float = 72
    var fill: RGBAColour = .white
    var stroke: StrokeStyle = StrokeStyle()
    var shadow: ShadowStyle = ShadowStyle()
    var glow: GlowStyle = GlowStyle()
    var pill: PillStyle = PillStyle()

    /// Vertical placement on the render canvas (R2.1 / R3.1).
    var anchor: CaptionAnchor = .bottom
    /// Vertical inset (px in render-canvas units) from the anchor edge.
    var verticalInset: Float = 96
    /// Letter-spacing in display-unit kerning (px).
    var letterSpacing: Float = 0

    var enterAnimation: CaptionEnterAnimation = .none
    var exitAnimation: CaptionExitAnimation = .none
    var enterDuration: Double = 0.25
    var exitDuration: Double = 0.25
    /// Direction parameter used by `slide` animations.
    var slideDirection: SlideDirection = .fromBottom

    /// Active-word recolour when `WordTiming` arrays exist; defaults to yellow.
    var wordHighlightFill: RGBAColour = .yellow

    static let identity = CaptionStyle()

    /// Explicit no-arg init because the custom `init(from:)` below suppresses
    /// the synthesised memberwise / default init; the property defaults still
    /// fully define the identity style.
    init() {}

    mutating func clamp() {
        fontSize = max(8, min(512, fontSize))
        stroke.width = max(0, min(64, stroke.width))
        shadow.blur = max(0, min(64, shadow.blur))
        glow.radius = max(0, min(128, glow.radius))
        pill.cornerRadius = max(0, min(128, pill.cornerRadius))
        pill.paddingX = max(0, min(128, pill.paddingX))
        pill.paddingY = max(0, min(128, pill.paddingY))
        verticalInset = max(0, min(2160, verticalInset))
        letterSpacing = max(-32, min(64, letterSpacing))
        enterDuration = max(0, min(5, enterDuration))
        exitDuration = max(0, min(5, exitDuration))
    }

    /// Custom decoder so a partial style object (e.g. a hand-edited `.lccaption`
    /// or a v1 preset missing a v2 field) decodes to the property defaults
    /// instead of throwing on the first missing key. The synthesised decoder
    /// would otherwise block every forward-compatible open path.
    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fill, stroke, shadow, glow, pill,
             anchor, verticalInset, letterSpacing,
             enterAnimation, exitAnimation, enterDuration, exitDuration,
             slideDirection, wordHighlightFill
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = try c.decodeIfPresent(String.self, forKey: .fontName) { fontName = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .fontSize) { fontSize = v }
        if let v = try c.decodeIfPresent(RGBAColour.self, forKey: .fill) { fill = v }
        if let v = try c.decodeIfPresent(StrokeStyle.self, forKey: .stroke) { stroke = v }
        if let v = try c.decodeIfPresent(ShadowStyle.self, forKey: .shadow) { shadow = v }
        if let v = try c.decodeIfPresent(GlowStyle.self, forKey: .glow) { glow = v }
        if let v = try c.decodeIfPresent(PillStyle.self, forKey: .pill) { pill = v }
        if let v = try c.decodeIfPresent(CaptionAnchor.self, forKey: .anchor) { anchor = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .verticalInset) { verticalInset = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .letterSpacing) { letterSpacing = v }
        if let v = try c.decodeIfPresent(CaptionEnterAnimation.self, forKey: .enterAnimation) { enterAnimation = v }
        if let v = try c.decodeIfPresent(CaptionExitAnimation.self, forKey: .exitAnimation) { exitAnimation = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .enterDuration) { enterDuration = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .exitDuration) { exitDuration = v }
        if let v = try c.decodeIfPresent(SlideDirection.self, forKey: .slideDirection) { slideDirection = v }
        if let v = try c.decodeIfPresent(RGBAColour.self, forKey: .wordHighlightFill) { wordHighlightFill = v }
    }

    /// Stable digest used as the cache key by the title rasteriser. Encodes
    /// every parameter that affects pixels, but excludes animation timing — the
    /// rasteriser caches static frames; the compositor applies animation per frame.
    var rasterHash: Int {
        var hasher = Hasher()
        hasher.combine(fontName)
        hasher.combine(fontSize)
        hasher.combine(fill)
        hasher.combine(stroke)
        hasher.combine(shadow)
        hasher.combine(glow)
        hasher.combine(pill)
        hasher.combine(anchor)
        hasher.combine(verticalInset)
        hasher.combine(letterSpacing)
        hasher.combine(wordHighlightFill)
        return hasher.finalize()
    }
}

// MARK: - Caption Tracks

/// A single word inside a caption line, with its own time range for karaoke-style
/// highlighting. Populated by ASR (Phase 29) when available; `nil` otherwise.
nonisolated struct WordTiming: Hashable, Codable, Sendable {
    var range: CMTimeRange
    var word: String

    init(range: CMTimeRange, word: String) {
        self.range = range
        self.word = word
    }

    private enum CodingKeys: String, CodingKey {
        case startValue, startScale, durationValue, durationScale, word
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sv = try c.decode(Int64.self, forKey: .startValue)
        let ss = try c.decode(Int32.self, forKey: .startScale)
        let dv = try c.decode(Int64.self, forKey: .durationValue)
        let ds = try c.decode(Int32.self, forKey: .durationScale)
        // CMTime with a non-positive timescale is invalid (and crashes on
        // arithmetic); a corrupted document must not be allowed to construct one.
        // Fall back to the project's default 600 timescale instead.
        range = CMTimeRange(
            start: CMTime(value: sv, timescale: ss > 0 ? ss : 600),
            duration: CMTime(value: dv, timescale: ds > 0 ? ds : 600))
        word = try c.decode(String.self, forKey: .word)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let start = range.start.isNumeric ? range.start : .zero
        let dur = range.duration.isNumeric ? range.duration : .zero
        try c.encode(start.value, forKey: .startValue)
        try c.encode(start.timescale == 0 ? 600 : start.timescale, forKey: .startScale)
        try c.encode(dur.value, forKey: .durationValue)
        try c.encode(dur.timescale == 0 ? 600 : dur.timescale, forKey: .durationScale)
        try c.encode(word, forKey: .word)
    }
}

/// One caption cue: a piece of text active over a time range, optionally split
/// into per-word timings.
///
/// `style` is a Phase-30 per-line override; `nil` means "use the track default".
nonisolated struct CaptionLine: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var range: CMTimeRange
    var text: String
    var words: [WordTiming]?
    var style: CaptionStyle?

    init(id: UUID = UUID(),
         range: CMTimeRange,
         text: String,
         words: [WordTiming]? = nil,
         style: CaptionStyle? = nil) {
        self.id = id
        self.range = range
        self.text = text
        self.words = words
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id, startValue, startScale, durationValue, durationScale, text, words, style
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let sv = try c.decode(Int64.self, forKey: .startValue)
        let ss = try c.decode(Int32.self, forKey: .startScale)
        let dv = try c.decode(Int64.self, forKey: .durationValue)
        let ds = try c.decode(Int32.self, forKey: .durationScale)
        // CMTime with a non-positive timescale is invalid; fall back to 600
        // rather than letting a corrupted document construct one.
        range = CMTimeRange(
            start: CMTime(value: sv, timescale: ss > 0 ? ss : 600),
            duration: CMTime(value: dv, timescale: ds > 0 ? ds : 600))
        text = try c.decode(String.self, forKey: .text)
        words = try c.decodeIfPresent([WordTiming].self, forKey: .words)
        style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        let start = range.start.isNumeric ? range.start : .zero
        let dur = range.duration.isNumeric ? range.duration : .zero
        try c.encode(start.value, forKey: .startValue)
        try c.encode(start.timescale == 0 ? 600 : start.timescale, forKey: .startScale)
        try c.encode(dur.value, forKey: .durationValue)
        try c.encode(dur.timescale == 0 ? 600 : dur.timescale, forKey: .durationScale)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(words, forKey: .words)
        try c.encodeIfPresent(style, forKey: .style)
    }

    /// Latest end-time of either the line or any of its words. Used to extend
    /// `Project.duration` so a caption past the last clip stays on screen.
    var endTime: CMTime {
        let lineEnd = range.end
        let wordEnd = words?.reduce(CMTime.zero) { CMTimeMaximum($0, $1.range.end) } ?? .zero
        return CMTimeMaximum(lineEnd, wordEnd)
    }
}

/// An ordered lane of caption lines. Independent of video / audio tracks so a
/// project can carry multiple languages or speaker streams in parallel.
@Observable
final class CaptionTrack: Identifiable {
    let id: UUID
    var name: String
    var isMuted = false
    private(set) var lines: [CaptionLine]
    /// Default styling applied to every line that does not override `style`.
    var defaultStyle: CaptionStyle = .identity

    /// `id` is `let` so it is stable for the lifetime of the runtime object.
    /// Snapshot restoration and document decode pass the original UUID so
    /// commands captured against the old identity keep working after undo/open.
    init(id: UUID = UUID(), name: String, lines: [CaptionLine] = []) {
        self.id = id
        self.name = name
        self.lines = lines.sorted { $0.range.start < $1.range.start }
    }

    func addLine(_ line: CaptionLine) {
        if let i = lines.firstIndex(where: { $0.range.start > line.range.start }) {
            lines.insert(line, at: i)
        } else {
            lines.append(line)
        }
    }

    func removeLine(id: CaptionLine.ID) {
        lines.removeAll { $0.id == id }
    }

    func updateLine(_ updated: CaptionLine) {
        guard let i = lines.firstIndex(where: { $0.id == updated.id }) else { return }
        lines[i] = updated
        lines.sort { $0.range.start < $1.range.start }
    }

    func replaceLines(_ newLines: [CaptionLine]) {
        lines = newLines.sorted { $0.range.start < $1.range.start }
    }

    /// Latest end time across every line (and any nested word).
    var endTime: CMTime {
        lines.reduce(.zero) { CMTimeMaximum($0, $1.endTime) }
    }
}

// MARK: - Timeline Markers

/// A named point in time on the project timeline. Hand-placed by the user, or
/// emitted in bulk by future phases (Phase 34 beat detection, Phase 44 chapter
/// finishing). Markers are annotations, not content: they do not extend
/// `Project.duration`.
nonisolated struct TimelineMarker: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var time: CMTime
    var name: String
    /// Optional accent for the marker glyph; `nil` ⇒ default ruler accent.
    var colour: RGBAColour?

    init(id: UUID = UUID(), time: CMTime, name: String = "Marker", colour: RGBAColour? = nil) {
        self.id = id
        self.time = time
        self.name = name
        self.colour = colour
    }

    /// `time` is nested as a `CMTimeCode`-shaped object (`{value, timescale}`)
    /// so the document representation matches caption lines / keyframes.
    private enum CodingKeys: String, CodingKey { case id, time, name, colour }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Marker"
        colour = try c.decodeIfPresent(RGBAColour.self, forKey: .colour)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(colour, forKey: .colour)
    }
}

// MARK: - Audio master bus (P16 infrastructure)

/// Per-audio-track input on the master bus: independent pan and linear gain.
/// `id == Track.id` so the input is keyed against the project's audio tracks.
nonisolated struct TrackInput: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    /// Stereo balance, −1 (full L) … +1 (full R). Defaults to centre.
    var pan: Float
    /// Linear gain, 0…2 (≈ −∞…+6 dB). Defaults to unity.
    var gain: Float

    init(id: UUID, pan: Float = 0, gain: Float = 1) {
        self.id = id
        self.pan = pan
        self.gain = gain
    }

    mutating func clamp() {
        pan = max(-1, min(1, pan))
        gain = max(0, min(2, gain))
    }
}

/// A per-clip envelope of linear-gain ramps applied **in addition to** the
/// transition crossfade ramps already written by `CompositionBuilder`. An empty
/// envelope leaves the existing audio mix bit-identical to the pre-bus path.
nonisolated struct VolumeEnvelope: Hashable, Codable, Sendable {
    /// A linear ramp between two volumes over a **clip-relative** time range
    /// (`range.start == .zero` is the clip's first frame). The composition
    /// builder shifts it onto each piece's effective timeline position at
    /// render time, so the automation moves with the clip on drag / trim /
    /// split and is clamped to the clip's duration.
    nonisolated struct Ramp: Hashable, Codable, Sendable {
        var range: CMTimeRange
        var fromVolume: Float
        var toVolume: Float

        init(range: CMTimeRange, fromVolume: Float, toVolume: Float) {
            self.range = range
            self.fromVolume = fromVolume
            self.toVolume = toVolume
        }

        private enum CodingKeys: String, CodingKey {
            case startValue, startScale, durationValue, durationScale, fromVolume, toVolume
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let sv = try c.decode(Int64.self, forKey: .startValue)
            let ss = try c.decode(Int32.self, forKey: .startScale)
            let dv = try c.decode(Int64.self, forKey: .durationValue)
            let ds = try c.decode(Int32.self, forKey: .durationScale)
            // Defensive: a zero/negative timescale is invalid; fall back to 600.
            // Also ensure duration is non-negative to prevent invalid CMTimeRange.
            range = CMTimeRange(
                start: CMTime(value: sv, timescale: ss > 0 ? ss : 600),
                duration: CMTime(value: max(0, dv), timescale: ds > 0 ? ds : 600))
            fromVolume = try c.decodeIfPresent(Float.self, forKey: .fromVolume) ?? 1
            toVolume = try c.decodeIfPresent(Float.self, forKey: .toVolume) ?? 1
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            let s = range.start.isNumeric ? range.start : .zero
            let d = range.duration.isNumeric ? range.duration : .zero
            try c.encode(s.value, forKey: .startValue)
            try c.encode(s.timescale == 0 ? 600 : s.timescale, forKey: .startScale)
            try c.encode(d.value, forKey: .durationValue)
            try c.encode(d.timescale == 0 ? 600 : d.timescale, forKey: .durationScale)
            try c.encode(fromVolume, forKey: .fromVolume)
            try c.encode(toVolume, forKey: .toVolume)
        }
    }

    /// Linear fade from 0→1 at the clip's head; `.zero` ⇒ no fade-in.
    var fadeIn: CMTime
    /// Linear fade from 1→0 at the clip's tail; `.zero` ⇒ no fade-out.
    var fadeOut: CMTime
    /// Free-form ramps applied on top of `fadeIn` / `fadeOut`.
    var ramps: [Ramp]

    init(fadeIn: CMTime = .zero, fadeOut: CMTime = .zero, ramps: [Ramp] = []) {
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.ramps = ramps
    }

    var isEmpty: Bool {
        fadeIn == .zero && fadeOut == .zero && ramps.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case fadeInValue, fadeInScale, fadeOutValue, fadeOutScale, ramps
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fiv = try c.decodeIfPresent(Int64.self, forKey: .fadeInValue) ?? 0
        let fis = try c.decodeIfPresent(Int32.self, forKey: .fadeInScale) ?? 600
        let fov = try c.decodeIfPresent(Int64.self, forKey: .fadeOutValue) ?? 0
        let fos = try c.decodeIfPresent(Int32.self, forKey: .fadeOutScale) ?? 600
        fadeIn = CMTime(value: fiv, timescale: fis > 0 ? fis : 600)
        fadeOut = CMTime(value: fov, timescale: fos > 0 ? fos : 600)
        ramps = try c.decodeIfPresent([Ramp].self, forKey: .ramps) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let fi = fadeIn.isNumeric ? fadeIn : .zero
        let fo = fadeOut.isNumeric ? fadeOut : .zero
        try c.encode(fi.value, forKey: .fadeInValue)
        try c.encode(fi.timescale == 0 ? 600 : fi.timescale, forKey: .fadeInScale)
        try c.encode(fo.value, forKey: .fadeOutValue)
        try c.encode(fo.timescale == 0 ? 600 : fo.timescale, forKey: .fadeOutScale)
        if !ramps.isEmpty { try c.encode(ramps, forKey: .ramps) }
    }

    /// Returns the effective fade-in / fade-out clamped to `clipDuration`. When
    /// `fadeIn + fadeOut > clipDuration`, each fade is reduced to
    /// `clipDuration / 2`. Clamping happens at *render* time so a temporary
    /// shortening doesn't lose the user's authored fades.
    func clampedFades(clipDuration: CMTime) -> (fadeIn: CMTime, fadeOut: CMTime) {
        guard clipDuration > .zero else { return (.zero, .zero) }
        let fi = CMTimeMaximum(.zero, CMTimeMinimum(fadeIn, clipDuration))
        let fo = CMTimeMaximum(.zero, CMTimeMinimum(fadeOut, clipDuration))
        let sum = fi + fo
        if sum <= clipDuration { return (fi, fo) }
        let half = CMTimeMultiplyByRatio(clipDuration, multiplier: 1, divisor: 2)
        return (half, half)
    }

    /// Intersects `range` with the clip's effective range so a ramp that
    /// extends past the clip end clamps to the clip end (R6.4).
    static func clampedRange(_ range: CMTimeRange, to clipRange: CMTimeRange) -> CMTimeRange? {
        let intersection = range.intersection(clipRange)
        return intersection.duration > .zero ? intersection : nil
    }
}

/// A peak + RMS amplitude snapshot from the master bus's mixer tap. Updated on
/// the audio thread and surfaced through the bus's `@Observable` accessor.
nonisolated struct AudioMeterSnapshot: Hashable, Sendable {
    var peakLeft: Float
    var peakRight: Float
    var rmsLeft: Float
    var rmsRight: Float
    /// Monotonic wall-clock at sample time; the inspector's hold/decay uses it
    /// to debounce between rapid updates.
    var sampledAt: ContinuousClock.Instant

    static let silent = AudioMeterSnapshot(
        peakLeft: 0, peakRight: 0, rmsLeft: 0, rmsRight: 0,
        sampledAt: ContinuousClock.now)
}


// MARK: - Project

/// The editable document: imported media plus the multi-track arrangement and
/// the render settings used for preview and export.
@Observable
final class Project {
    var name = "Untitled"
    var mediaItems: [MediaItem] = []
    var videoTracks: [Track]
    var audioTracks: [Track]
    var captionTracks: [CaptionTrack] = []
    /// Timeline markers sorted by `time`. Mutation paths on `EditorModel`
    /// preserve the invariant so draw / lookup code can treat the list as
    /// ordered without re-sorting per frame.
    var markers: [TimelineMarker] = []

    /// Output canvas size for preview and export.
    var renderSize = CGSize(width: 1920, height: 1080)
    /// Output frame rate (frames per second).
    var frameRate: Double = 30
    /// Working colour space used by the compositor's `CIContext` and stamped
    /// onto every output `CVPixelBuffer` attachment.
    var workingColourSpace: WorkingColourSpace = .sRGB

    // MARK: - Audio master bus (P16) parameters

    /// Master-bus output gain (linear, 0…2 ≈ −∞…+6 dB). Defaults to unity so
    /// a project with no audio-bus edits renders bit-identically to today's
    /// behaviour.
    var masterGain: Float = 1
    /// Per-audio-track inputs on the bus. Tracks are matched by `id` lazily;
    /// a missing entry implies defaults (pan 0, gain 1).
    var trackInputs: [TrackInput] = []

    init() {
        videoTracks = [Track(name: "V1", kind: .video)]
        audioTracks = [Track(name: "A1", kind: .audio)]
    }

    /// Looks up the bus input for a track, returning defaults when not yet
    /// authored. Callers that mutate read-then-write via `setTrackInput`.
    func trackInput(for trackID: Track.ID) -> TrackInput {
        trackInputs.first(where: { $0.id == trackID }) ?? TrackInput(id: trackID)
    }

    func media(for id: MediaItem.ID) -> MediaItem? {
        mediaItems.first { $0.id == id }
    }

    /// Longest end time across every track — the project's total duration.
    /// Caption tracks count too, so a final caption past the last clip extends
    /// the timeline rather than being clipped off the end. Markers are
    /// annotations, not content, so they do not contribute here.
    var duration: CMTime {
        let av = (videoTracks + audioTracks).reduce(CMTime.zero) { CMTimeMaximum($0, $1.endTime) }
        let captions = captionTracks.reduce(CMTime.zero) { CMTimeMaximum($0, $1.endTime) }
        return CMTimeMaximum(av, captions)
    }
}
