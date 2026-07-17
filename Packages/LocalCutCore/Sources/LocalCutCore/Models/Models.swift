import Foundation
import CoreMedia
import CoreGraphics
import CoreVideo

// MARK: - Working colour space

/// The project's working colour space. Tags the compositor's `CIContext`
/// `workingColorSpace` and every output `CVPixelBuffer` so downstream
/// `AVAssetExportSession` / `AVAssetWriter` carry it through.
public enum WorkingColourSpace: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case sRGB
    case displayP3
    case rec709
    case rec2020

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .rec709: "Rec. 709"
        case .rec2020: "Rec. 2020"
        }
    }

    /// `CGColorSpace` used as the `CIContext.workingColorSpace` and the
    /// render-time `colorSpace` argument.
    public var cgColorSpace: CGColorSpace {
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
    public var cvColorPrimaries: CFString {
        switch self {
        case .sRGB, .rec709: kCVImageBufferColorPrimaries_ITU_R_709_2
        case .displayP3: kCVImageBufferColorPrimaries_P3_D65
        case .rec2020: kCVImageBufferColorPrimaries_ITU_R_2020
        }
    }

    /// Value for the `kCVImageBufferTransferFunctionKey` attachment.
    public var cvTransferFunction: CFString {
        switch self {
        case .sRGB, .displayP3: kCVImageBufferTransferFunction_sRGB
        case .rec709, .rec2020: kCVImageBufferTransferFunction_ITU_R_709_2
        }
    }

    /// Value for the `kCVImageBufferYCbCrMatrixKey` attachment.
    public var cvYCbCrMatrix: CFString {
        switch self {
        case .sRGB, .displayP3, .rec709, .rec2020: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }
}

// MARK: - Timeline

public enum TrackKind: Hashable, Sendable {
    case video
    case audio
    /// Phase 45: layout track for Program Mode scene-switch replay.
    case layout
}

// MARK: - Colour Grading

/// Perceptual colour-adjustment parameters with neutral defaults and clamping.
public struct ColourGrade: Hashable, Codable, Sendable {
    public var exposure: Float = 0
    public var contrast: Float = 1
    public var saturation: Float = 1
    public var temperatureOffset: Float = 0
    public var tintOffset: Float = 0

    public static let neutral = ColourGrade()

    public init() {}

    public init(exposure: Float, contrast: Float, saturation: Float,
                temperatureOffset: Float, tintOffset: Float) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperatureOffset = temperatureOffset
        self.tintOffset = tintOffset
    }

    public mutating func clamp() {
        exposure = max(-2, min(2, exposure))
        contrast = max(0.5, min(1.5, contrast))
        saturation = max(0, min(2, saturation))
        temperatureOffset = max(-4000, min(4000, temperatureOffset))
        tintOffset = max(-150, min(150, tintOffset))
    }
}

/// Skin smoothing parameters with neutral defaults and clamping.
public struct SkinSmoothEffect: Hashable, Codable, Sendable {
    public var strength: Keyframed<Float>
    public var maskWarmthBias: Float = 0
    public var maskLuminanceGate: Float = 0.1
    public var bypass: Bool = false

    public init() {
        self.strength = Keyframed<Float>(defaultValue: 0)
    }

    public static var neutral: SkinSmoothEffect { SkinSmoothEffect() }

    /// Evaluates the authored curve and sanitizes it for UI and render use.
    /// Bezier handles may intentionally overshoot their keyframe values, while
    /// corrupted persisted handles can be non-finite; the effect contract is
    /// always a finite strength in `0...1`.
    public func strength(at time: CMTime) -> Float {
        Self.clampedStrength(strength.bezierValue(at: time))
    }

    public static func clampedStrength(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    public mutating func clamp() {
        maskWarmthBias = max(-1, min(1, maskWarmthBias))
        maskLuminanceGate = max(0, min(1, maskLuminanceGate))
        let clampedKeyframes = strength.keyframes.map { kf in
            Keyframe(id: kf.id, time: kf.time, value: Self.clampedStrength(kf.value),
                     incomingHandle: kf.incomingHandle,
                     outgoingHandle: kf.outgoingHandle)
        }
        let clampedDefault = Self.clampedStrength(strength.defaultValue)
        strength = Keyframed<Float>(keyframes: clampedKeyframes, defaultValue: clampedDefault)
    }
}

// MARK: - Film look effects

private func clamped(_ value: Float, to range: ClosedRange<Float>) -> Float {
    guard value.isFinite else {
        return range.contains(0) ? 0 : range.lowerBound
    }
    return max(range.lowerBound, min(range.upperBound, value))
}

private func clampedKeyframed(_ value: Keyframed<Float>, to range: ClosedRange<Float>) -> Keyframed<Float> {
    let keyframes = value.keyframes.map { keyframe in
        Keyframe(id: keyframe.id, time: keyframe.time, value: clamped(keyframe.value, to: range),
                 incomingHandle: keyframe.incomingHandle,
                 outgoingHandle: keyframe.outgoingHandle)
    }
    return Keyframed(keyframes: keyframes, defaultValue: clamped(value.defaultValue, to: range))
}

/// Procedural film-grain parameters. `amount` is keyframed in clip-local time;
/// `size` is authored as a source-pixel scale so preview and export match.
public struct GrainEffect: Hashable, Codable, Sendable {
    public var amount: Keyframed<Float>
    public var size: Float
    public var monochrome: Bool
    public var seed: UInt64

    private enum CodingKeys: String, CodingKey {
        case amount, size, monochrome, seed
    }

    public init(amount: Keyframed<Float> = Keyframed(defaultValue: 0),
                size: Float = 1,
                monochrome: Bool = true,
                seed: UInt64 = 0) {
        self.amount = amount
        self.size = size
        self.monochrome = monochrome
        self.seed = seed
        clamp()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        amount = try values.decodeIfPresent(Keyframed<Float>.self, forKey: .amount)
            ?? Keyframed(defaultValue: 0)
        size = try values.decodeIfPresent(Float.self, forKey: .size) ?? 1
        monochrome = try values.decodeIfPresent(Bool.self, forKey: .monochrome) ?? true
        seed = try values.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
        clamp()
    }

    public static var neutral: GrainEffect { GrainEffect() }

    public var isNeutral: Bool {
        amount.defaultValue == 0 && amount.keyframes.allSatisfy { $0.value == 0 }
    }

    public mutating func clamp() {
        amount = clampedKeyframed(amount, to: 0...1)
        size = clamped(size, to: 0.25...8)
    }

    public func amount(at time: CMTime) -> Float {
        clamped(amount.bezierValue(at: time), to: 0...1)
    }
}

/// Bright-edge red/orange bleed used by film-emulation presets.
public struct HalationEffect: Hashable, Codable, Sendable {
    public var strength: Keyframed<Float>
    public var threshold: Float
    public var radius: Float
    public var redBoost: Float

    private enum CodingKeys: String, CodingKey {
        case strength, threshold, radius, redBoost
    }

    public init(strength: Keyframed<Float> = Keyframed(defaultValue: 0),
                threshold: Float = 0.72,
                radius: Float = 16,
                redBoost: Float = 0.85) {
        self.strength = strength
        self.threshold = threshold
        self.radius = radius
        self.redBoost = redBoost
        clamp()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        strength = try values.decodeIfPresent(Keyframed<Float>.self, forKey: .strength)
            ?? Keyframed(defaultValue: 0)
        threshold = try values.decodeIfPresent(Float.self, forKey: .threshold) ?? 0.72
        radius = try values.decodeIfPresent(Float.self, forKey: .radius) ?? 16
        redBoost = try values.decodeIfPresent(Float.self, forKey: .redBoost) ?? 0.85
        clamp()
    }

    public static var neutral: HalationEffect { HalationEffect() }

    public var isNeutral: Bool {
        strength.defaultValue == 0 && strength.keyframes.allSatisfy { $0.value == 0 }
    }

    public mutating func clamp() {
        strength = clampedKeyframed(strength, to: 0...1)
        threshold = clamped(threshold, to: 0...1)
        radius = clamped(radius, to: 0...80)
        redBoost = clamped(redBoost, to: 0...2)
    }

    public func strength(at time: CMTime) -> Float {
        clamped(strength.bezierValue(at: time), to: 0...1)
    }
}

/// Edge shading for look packs. Positive `amount` darkens edges; negative values
/// are allowed for light-leak style looks.
public struct VignetteEffect: Hashable, Codable, Sendable {
    public var amount: Keyframed<Float>
    public var radius: Float
    public var softness: Float

    private enum CodingKeys: String, CodingKey {
        case amount, radius, softness
    }

    public init(amount: Keyframed<Float> = Keyframed(defaultValue: 0),
                radius: Float = 0.65,
                softness: Float = 0.35) {
        self.amount = amount
        self.radius = radius
        self.softness = softness
        clamp()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        amount = try values.decodeIfPresent(Keyframed<Float>.self, forKey: .amount)
            ?? Keyframed(defaultValue: 0)
        radius = try values.decodeIfPresent(Float.self, forKey: .radius) ?? 0.65
        softness = try values.decodeIfPresent(Float.self, forKey: .softness) ?? 0.35
        clamp()
    }

    public static var neutral: VignetteEffect { VignetteEffect() }

    public var isNeutral: Bool {
        amount.defaultValue == 0 && amount.keyframes.allSatisfy { $0.value == 0 }
    }

    public mutating func clamp() {
        amount = clampedKeyframed(amount, to: -1...1)
        radius = clamped(radius, to: 0.05...2)
        softness = clamped(softness, to: 0.01...1)
    }

    public func amount(at time: CMTime) -> Float {
        clamped(amount.bezierValue(at: time), to: -1...1)
    }
}

/// An effect that can be applied to a video clip's source frames.
public enum Effect: Hashable, Codable, Sendable {
    case colourGrade(ColourGrade)
    case lut(bookmark: Data)
    case skinSmooth(SkinSmoothEffect)
    case grain(GrainEffect)
    case halation(HalationEffect)
    case vignette(VignetteEffect)

    public static func == (lhs: Effect, rhs: Effect) -> Bool {
        switch (lhs, rhs) {
        case (.colourGrade(let a), .colourGrade(let b)): a == b
        case (.lut(bookmark: let a), .lut(bookmark: let b)): a == b
        case (.skinSmooth(let a), .skinSmooth(let b)): a == b
        case (.grain(let a), .grain(let b)): a == b
        case (.halation(let a), .halation(let b)): a == b
        case (.vignette(let a), .vignette(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .colourGrade(let g): hasher.combine(0); hasher.combine(g)
        case .lut(bookmark: let d): hasher.combine(1); hasher.combine(d)
        case .skinSmooth(let s): hasher.combine(2); hasher.combine(s)
        case .grain(let g): hasher.combine(3); hasher.combine(g)
        case .halation(let h): hasher.combine(4); hasher.combine(h)
        case .vignette(let v): hasher.combine(5); hasher.combine(v)
        }
    }
}

extension Array where Element == Effect {
    public var hasLUT: Bool {
        contains { if case .lut = $0 { return true }; return false }
    }

    public func replacingLUT(bookmark: Data) -> [Effect] {
        var result: [Effect] = []
        var inserted = false
        for effect in self {
            if case .lut = effect {
                if !inserted {
                    result.append(.lut(bookmark: bookmark))
                    inserted = true
                }
            } else {
                result.append(effect)
            }
        }
        if !inserted { result.append(.lut(bookmark: bookmark)) }
        return result
    }

    public func removingLUT() -> [Effect] {
        filter { if case .lut = $0 { return false }; return true }
    }

    public var hasLookEffects: Bool {
        contains { $0.isLookEffect }
    }

    public var lookEffects: [Effect] {
        filter(\.isLookEffect)
    }

    public func replacingLookEffect(_ effect: Effect) -> [Effect] {
        guard let kind = effect.lookKind else { return self }
        let nonLooks = filter { !$0.isLookEffect }
        let looks = (lookEffects.filter { $0.lookKind != kind } + [effect])
            .sorted { ($0.lookKind?.sortIndex ?? 0) < ($1.lookKind?.sortIndex ?? 0) }
        return nonLooks + looks
    }

    public func removingLookEffects() -> [Effect] {
        filter { !$0.isLookEffect }
    }

    public func applyingLookEffects(_ lookEffects: [Effect]) -> [Effect] {
        removingLookEffects() + lookEffects.filter(\.isLookEffect)
    }
}

public enum LookEffectKind: String, Codable, Hashable, Sendable, CaseIterable {
    case grain
    case halation
    case vignette

    public var sortIndex: Int {
        switch self {
        case .halation: 0
        case .vignette: 1
        case .grain: 2
        }
    }

    public var displayName: String {
        switch self {
        case .grain: "Grain"
        case .halation: "Halation"
        case .vignette: "Vignette"
        }
    }
}

extension Effect {
    public var lookKind: LookEffectKind? {
        switch self {
        case .grain: .grain
        case .halation: .halation
        case .vignette: .vignette
        case .colourGrade, .lut, .skinSmooth: nil
        }
    }

    public var isLookEffect: Bool {
        lookKind != nil
    }

    public var isLUT: Bool {
        if case .lut = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .colourGrade: "Colour Grade"
        case .lut: "LUT"
        case .skinSmooth: "Skin Smooth"
        case .grain: "Grain"
        case .halation: "Halation"
        case .vignette: "Vignette"
        }
    }

    /// The primary keyframed parameter for look-pack effects — grain amount,
    /// halation strength, or vignette amount. `nil` for non-look effects. Used by
    /// the inspector's per-look keyframe editor so one code path drives all three.
    public var lookStrength: Keyframed<Float>? {
        switch self {
        case .grain(let g): g.amount
        case .halation(let h): h.strength
        case .vignette(let v): v.amount
        case .colourGrade, .lut, .skinSmooth: nil
        }
    }

    /// Evaluates a look effect's primary parameter using the same finite,
    /// effect-specific bounds as the render pipeline. Pass `nil` when the
    /// playhead is outside the selected clip to obtain the sanitized default.
    public func evaluatedLookStrength(at time: CMTime?) -> Float? {
        switch self {
        case .grain(let grain):
            return time.map(grain.amount(at:))
                ?? clamped(grain.amount.defaultValue, to: 0...1)
        case .halation(let halation):
            return time.map(halation.strength(at:))
                ?? clamped(halation.strength.defaultValue, to: 0...1)
        case .vignette(let vignette):
            return time.map(vignette.amount(at:))
                ?? clamped(vignette.amount.defaultValue, to: -1...1)
        case .colourGrade, .lut, .skinSmooth:
            return nil
        }
    }

    /// Returns a copy of a look effect with its primary keyframed parameter
    /// replaced (re-clamped). No-op for non-look effects.
    public func settingLookStrength(_ track: Keyframed<Float>) -> Effect {
        switch self {
        case .grain(var g): g.amount = track; g.clamp(); return .grain(g)
        case .halation(var h): h.strength = track; h.clamp(); return .halation(h)
        case .vignette(var v): v.amount = track; v.clamp(); return .vignette(v)
        case .colourGrade, .lut, .skinSmooth: return self
        }
    }

    /// Fixed render-pipeline precedence so the rendered result does not depend on
    /// the order in which inspector controls happened to be used. Colour grade and
    /// LUT come first, then skin smoothing, then the look-pack nodes in their
    /// documented order (halation → vignette → grain, so grain is laid down last
    /// and is not blurred or reshaped by the glow/shading passes).
    public var pipelineOrder: Int {
        switch self {
        case .colourGrade: 0
        case .lut: 1
        case .skinSmooth: 2
        case .halation: 3
        case .vignette: 4
        case .grain: 5
        }
    }
}

extension Array where Element == Effect {
    /// Returns the effects in canonical render order (`Effect.pipelineOrder`).
    /// The sort is stable, so two effects of the same kind keep their relative
    /// order. This is a render-time view only; the stored chain is left as-is.
    public func canonicalPipelineOrder() -> [Effect] {
        enumerated()
            .sorted {
                $0.element.pipelineOrder == $1.element.pipelineOrder
                    ? $0.offset < $1.offset
                    : $0.element.pipelineOrder < $1.element.pipelineOrder
            }
            .map(\.element)
    }
}

// MARK: - Transitions

/// The kinds of transition supported in v1.
public enum TransitionType: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case crossDissolve
    case wipe

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .crossDissolve: "Cross Dissolve"
        case .wipe: "Wipe"
        }
    }

    public var symbolName: String {
        switch self {
        case .crossDissolve: "circle.lefthalf.filled"
        case .wipe: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        }
    }
}

/// A transition placed at the cut where its owning (trailing) clip meets the
/// immediately-preceding adjacent clip on the same video track.
public struct Transition: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var type: TransitionType
    public var duration: CMTime
    public var wipeAngle: Double

    public init(id: UUID = UUID(),
                type: TransitionType = .crossDissolve,
                duration: CMTime,
                wipeAngle: Double = Transition.defaultWipeAngle) {
        self.id = id
        self.type = type
        self.duration = duration
        self.wipeAngle = wipeAngle
    }

    public static let defaultDuration = CMTime(value: 1, timescale: 2)
    public static let defaultWipeAngle: Double = 0

    public static func radians(fromDegrees degrees: Double) -> Double {
        degrees * .pi / 180
    }

    public static func degrees(fromRadians radians: Double) -> Double {
        let degrees = radians * 180 / .pi
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }
}

/// A single placement of (part of) a media item on a track's timeline.
public enum ClipMaskShape: String, Hashable, Codable, Sendable {
    case none
    case circle
    case roundedRect
}

public struct ClipGeometry: Hashable, Codable, Sendable {
    public var positionOffset: CGSize
    public var scale: CGFloat
    public var mask: ClipMaskShape

    public static let identity = ClipGeometry()

    public var isIdentity: Bool {
        positionOffset == .zero && scale == 1 && mask == .none
    }

    public init(positionOffset: CGSize = .zero,
                scale: CGFloat = 1,
                mask: ClipMaskShape = .none) {
        self.positionOffset = positionOffset
        self.scale = min(10, max(0.01, scale))
        self.mask = mask
    }
}

public struct Clip: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var mediaID: UUID
    public var sourceStart: CMTime
    public var duration: CMTime
    public var timelineStart: CMTime
    public var opacity: Float = 1
    public var geometry: ClipGeometry = .identity
    public var effects: [Effect] = []
    public var transition: Transition?
    public var volumeEnvelope: VolumeEnvelope = VolumeEnvelope()

    /// Keyframed transform animation for zoom-n-pan effects. Keyframes are in
    /// clip-source-local time and represent the clip's transform relative to its
    /// natural fit in the render canvas. Default is identity (no animation).
    public var transformKeyframes: Keyframed<Transform2D> = Keyframed(defaultValue: .identity)

    /// Per-clip speed curve for source-to-output retiming. The curve is authored
    /// in clip-source-local time: a source timestamp maps onto the timeline by
    /// integrating `1 / speed` from the clip in-point to that timestamp.
    public var speedCurve: Keyframed<Float> = TimeRemapping.identitySpeedCurve

    /// When true, AVFoundation keeps audio pitch stable while the clip is
    /// stretched. When false, audio follows the speed change as a varispeed effect.
    public var preservePitch = true

    /// Stretch quality used when `preservePitch` is true.
    public var pitchAlgorithm: TimePitchAlgorithm = .timeDomain

    /// Timeline duration after applying the speed curve to the selected source span.
    public var outputDuration: CMTime {
        TimeRemapping.outputDuration(sourceDuration: duration, speedCurve: speedCurve)
    }

    public var timelineEnd: CMTime { timelineStart + outputDuration }
    public var timeRangeInSource: CMTimeRange { CMTimeRange(start: sourceStart, duration: duration) }

    public var hasTimeRemap: Bool {
        TimeRemapping.hasNonIdentitySpeed(speedCurve)
    }

    public mutating func clampTimeRemap() {
        speedCurve = TimeRemapping.clampedCurve(speedCurve)
    }

    public func sourceOffset(forOutputOffset outputOffset: CMTime) -> CMTime {
        TimeRemapping.sourceOffset(
            forOutputOffset: outputOffset,
            sourceDuration: duration,
            speedCurve: speedCurve)
    }

    public func outputOffset(forSourceOffset sourceOffset: CMTime) -> CMTime {
        TimeRemapping.outputOffset(
            forSourceOffset: sourceOffset,
            sourceDuration: duration,
            speedCurve: speedCurve)
    }

    public init(mediaID: UUID,
                sourceStart: CMTime,
                duration: CMTime,
                timelineStart: CMTime,
                opacity: Float = 1,
                geometry: ClipGeometry = .identity,
                effects: [Effect] = [],
                transition: Transition? = nil,
                volumeEnvelope: VolumeEnvelope = VolumeEnvelope(),
                transformKeyframes: Keyframed<Transform2D> = Keyframed(defaultValue: .identity),
                speedCurve: Keyframed<Float> = TimeRemapping.identitySpeedCurve,
                preservePitch: Bool = true,
                pitchAlgorithm: TimePitchAlgorithm = .timeDomain) {
        self.mediaID = mediaID
        self.sourceStart = sourceStart
        self.duration = duration
        self.timelineStart = timelineStart
        self.opacity = opacity
        self.geometry = geometry
        self.effects = effects
        self.transition = transition
        self.volumeEnvelope = volumeEnvelope
        self.transformKeyframes = transformKeyframes
        self.speedCurve = speedCurve
        self.preservePitch = preservePitch
        self.pitchAlgorithm = pitchAlgorithm
    }
}

// MARK: - Caption Style

public struct RGBAColour: Hashable, Codable, Sendable, Interpolatable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float

    public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = RGBAColour(red: 1, green: 1, blue: 1)
    public static let black = RGBAColour(red: 0, green: 0, blue: 0)
    public static let clear = RGBAColour(red: 0, green: 0, blue: 0, alpha: 0)
    public static let yellow = RGBAColour(red: 1, green: 0.85, blue: 0.2)

    /// Cached sRGB color space to avoid re-creating on every `cgColor` call
    /// (called per-frame from the compositor).
    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public var cgColor: CGColor {
        CGColor(
            colorSpace: Self.sRGBColorSpace,
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)])
            ?? CGColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    public static func lerp(_ a: RGBAColour, _ b: RGBAColour, t: Float) -> RGBAColour {
        RGBAColour(
            red: Float.lerp(a.red, b.red, t: t),
            green: Float.lerp(a.green, b.green, t: t),
            blue: Float.lerp(a.blue, b.blue, t: t),
            alpha: Float.lerp(a.alpha, b.alpha, t: t))
    }
}

public struct StrokeStyle: Hashable, Codable, Sendable {
    public var colour: RGBAColour = .black
    public var width: Float = 0
    public init() {}
    public init(colour: RGBAColour, width: Float) {
        self.colour = colour
        self.width = width
    }
}

public struct ShadowStyle: Hashable, Codable, Sendable {
    public var colour: RGBAColour = RGBAColour(red: 0, green: 0, blue: 0, alpha: 0.5)
    public var offsetX: Float = 0
    public var offsetY: Float = -2
    public var blur: Float = 4
    public var radius: Float { blur }
    public init() {}
    public init(colour: RGBAColour, offsetX: Float, offsetY: Float, blur: Float) {
        self.colour = colour
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blur = blur
    }
}

public struct GlowStyle: Hashable, Codable, Sendable {
    public var colour: RGBAColour = .clear
    public var radius: Float = 0
    public init() {}
    public init(colour: RGBAColour, radius: Float) {
        self.colour = colour
        self.radius = radius
    }
}

public struct PillStyle: Hashable, Codable, Sendable {
    public var colour: RGBAColour = .clear
    public var cornerRadius: Float = 12
    public var paddingX: Float = 16
    public var paddingY: Float = 8
    public init() {}
    public init(colour: RGBAColour, cornerRadius: Float, paddingX: Float, paddingY: Float) {
        self.colour = colour
        self.cornerRadius = cornerRadius
        self.paddingX = paddingX
        self.paddingY = paddingY
    }
}

public enum CaptionEnterAnimation: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case none, pop, bounce, slide, typewriter
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: "None"
        case .pop: "Pop"
        case .bounce: "Bounce"
        case .slide: "Slide"
        case .typewriter: "Typewriter"
        }
    }
}

public enum CaptionExitAnimation: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case none, pop, slide, fade
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: "None"
        case .pop: "Pop"
        case .slide: "Slide"
        case .fade: "Fade"
        }
    }
}

public enum SlideDirection: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case fromBottom, fromTop, fromLeft, fromRight
    public var id: String { rawValue }
}

public enum CaptionAnchor: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case top, middle, bottom
    public var id: String { rawValue }
}

public struct CaptionStyle: Hashable, Codable, Sendable {
    public var fontName: String = "Helvetica-Bold"
    public var fontSize: Float = 72
    public var fill: RGBAColour = .white
    public var stroke: StrokeStyle = StrokeStyle()
    public var shadow: ShadowStyle = ShadowStyle()
    public var glow: GlowStyle = GlowStyle()
    public var pill: PillStyle = PillStyle()
    public var anchor: CaptionAnchor = .bottom
    public var verticalInset: Float = 96
    public var letterSpacing: Float = 0
    public var enterAnimation: CaptionEnterAnimation = .none
    public var exitAnimation: CaptionExitAnimation = .none
    public var enterDuration: Double = 0.25
    public var exitDuration: Double = 0.25
    public var slideDirection: SlideDirection = .fromBottom
    public var wordHighlightFill: RGBAColour = .yellow

    public static let identity = CaptionStyle()

    public init() {}

    public mutating func clamp() {
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

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fill, stroke, shadow, glow, pill,
             anchor, verticalInset, letterSpacing,
             enterAnimation, exitAnimation, enterDuration, exitDuration,
             slideDirection, wordHighlightFill
    }

    public init(from decoder: any Decoder) throws {
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

    public var rasterHash: Int {
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

/// The line-local animated caption-style parameters from Phase 30 R2.3.
/// The base `CaptionStyle` still carries static preset/default values; this
/// bundle layers keyframed overrides on top for the subset that needs per-line
/// animation.
public struct CaptionStyleKeyframeValues: Hashable, Sendable {
    public var fill: RGBAColour
    public var scale: Float
    public var offsetX: Float
    public var offsetY: Float
    public var opacity: Float
    public var letterSpacing: Float

    public init(fill: RGBAColour = .white,
                scale: Float = 1,
                offsetX: Float = 0,
                offsetY: Float = 0,
                opacity: Float = 1,
                letterSpacing: Float = 0) {
        self.fill = fill
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.opacity = opacity
        self.letterSpacing = letterSpacing
        clamp()
    }

    public init(baseStyle: CaptionStyle) {
        self.init(fill: baseStyle.fill,
                  scale: 1,
                  offsetX: 0,
                  offsetY: 0,
                  opacity: 1,
                  letterSpacing: baseStyle.letterSpacing)
    }

    public mutating func clamp() {
        fill.red = max(0, min(1, fill.red))
        fill.green = max(0, min(1, fill.green))
        fill.blue = max(0, min(1, fill.blue))
        fill.alpha = max(0, min(1, fill.alpha))
        scale = max(0.1, min(4, scale))
        offsetX = max(-4096, min(4096, offsetX))
        offsetY = max(-4096, min(4096, offsetY))
        opacity = max(0, min(1, opacity))
        letterSpacing = max(-32, min(64, letterSpacing))
    }

    public var clamped: CaptionStyleKeyframeValues {
        var copy = self
        copy.clamp()
        return copy
    }
}

public struct CaptionStyleKeyframes: Hashable, Codable, Sendable {
    public var fill: Keyframed<RGBAColour>
    public var scale: Keyframed<Float>
    public var offsetX: Keyframed<Float>
    public var offsetY: Keyframed<Float>
    public var opacity: Keyframed<Float>
    public var letterSpacing: Keyframed<Float>

    public init(baseStyle: CaptionStyle = .identity) {
        let values = CaptionStyleKeyframeValues(baseStyle: baseStyle)
        self.init(defaultValues: values)
    }

    public init(defaultValues: CaptionStyleKeyframeValues) {
        let values = defaultValues.clamped
        fill = Keyframed(defaultValue: values.fill)
        scale = Keyframed(defaultValue: values.scale)
        offsetX = Keyframed(defaultValue: values.offsetX)
        offsetY = Keyframed(defaultValue: values.offsetY)
        opacity = Keyframed(defaultValue: values.opacity)
        letterSpacing = Keyframed(defaultValue: values.letterSpacing)
    }

    public var isEmpty: Bool {
        fill.keyframes.isEmpty
            && scale.keyframes.isEmpty
            && offsetX.keyframes.isEmpty
            && offsetY.keyframes.isEmpty
            && opacity.keyframes.isEmpty
            && letterSpacing.keyframes.isEmpty
    }

    public var keyframeCount: Int { allKeyframeTimes.count }

    public var allKeyframeTimes: [CMTime] {
        var times = Set<CMTime>()
        for time in fill.keyframes.map(\.time)
            + scale.keyframes.map(\.time)
            + offsetX.keyframes.map(\.time)
            + offsetY.keyframes.map(\.time)
            + opacity.keyframes.map(\.time)
            + letterSpacing.keyframes.map(\.time) {
            times.insert(time)
        }
        return Array(times).sorted()
    }

    public func hasKeyframe(at time: CMTime) -> Bool {
        // Use semantic time comparison (seconds) rather than CMTime value
        // equality, so differently-timescaled representations of the same
        // wall-clock time still match.
        let seconds = time.seconds
        return allKeyframeTimes.contains { abs($0.seconds - seconds) < 0.0005 }
    }

    public func values(at time: CMTime) -> CaptionStyleKeyframeValues {
        CaptionStyleKeyframeValues(
            fill: fill.value(at: time),
            scale: scale.value(at: time),
            offsetX: offsetX.value(at: time),
            offsetY: offsetY.value(at: time),
            opacity: opacity.value(at: time),
            letterSpacing: letterSpacing.value(at: time))
    }

    /// Returns the keyframed properties consumed by text rasterization. Scale,
    /// offsets, and opacity stay outside the style because the compositor applies
    /// them as post-raster image transforms.
    public func rasterStyle(base: CaptionStyle, at time: CMTime) -> CaptionStyle {
        let values = values(at: time)
        var style = base
        style.fill = values.fill
        style.letterSpacing = values.letterSpacing
        return style
    }

    public mutating func addOrUpdateKeyframes(at time: CMTime,
                                              values rawValues: CaptionStyleKeyframeValues) {
        let values = rawValues.clamped
        fill.addKeyframe(at: time, value: values.fill)
        scale.addKeyframe(at: time, value: values.scale)
        offsetX.addKeyframe(at: time, value: values.offsetX)
        offsetY.addKeyframe(at: time, value: values.offsetY)
        opacity.addKeyframe(at: time, value: values.opacity)
        letterSpacing.addKeyframe(at: time, value: values.letterSpacing)
    }

    public mutating func removeKeyframes(at time: CMTime) {
        fill.removeKeyframe(at: time)
        scale.removeKeyframe(at: time)
        offsetX.removeKeyframe(at: time)
        offsetY.removeKeyframe(at: time)
        opacity.removeKeyframe(at: time)
        letterSpacing.removeKeyframe(at: time)
    }
}

// MARK: - Caption Tracks

public struct WordTiming: Hashable, Codable, Sendable {
    public var range: CMTimeRange
    public var word: String

    public init(range: CMTimeRange, word: String) {
        self.range = range
        self.word = word
    }

    private enum CodingKeys: String, CodingKey {
        case startValue, startScale, durationValue, durationScale, word
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sv = try c.decode(Int64.self, forKey: .startValue)
        let ss = try c.decode(Int32.self, forKey: .startScale)
        let dv = try c.decode(Int64.self, forKey: .durationValue)
        let ds = try c.decode(Int32.self, forKey: .durationScale)
        range = CMTimeRange(
            start: CMTime(value: sv, timescale: ss > 0 ? ss : 600),
            duration: CMTime(value: dv, timescale: ds > 0 ? ds : 600))
        word = try c.decode(String.self, forKey: .word)
    }

    public func encode(to encoder: any Encoder) throws {
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

public struct CaptionLine: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var range: CMTimeRange
    public var text: String
    public var words: [WordTiming]?
    public var style: CaptionStyle?
    public var styleKeyframes: CaptionStyleKeyframes?

    public init(id: UUID = UUID(),
                range: CMTimeRange,
                text: String,
                words: [WordTiming]? = nil,
                style: CaptionStyle? = nil,
                styleKeyframes: CaptionStyleKeyframes? = nil) {
        self.id = id
        self.range = range
        self.text = text
        self.words = words
        self.style = style
        self.styleKeyframes = styleKeyframes
    }

    private enum CodingKeys: String, CodingKey {
        case id, startValue, startScale, durationValue, durationScale, text,
             words, style, styleKeyframes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let sv = try c.decode(Int64.self, forKey: .startValue)
        let ss = try c.decode(Int32.self, forKey: .startScale)
        let dv = try c.decode(Int64.self, forKey: .durationValue)
        let ds = try c.decode(Int32.self, forKey: .durationScale)
        range = CMTimeRange(
            start: CMTime(value: sv, timescale: ss > 0 ? ss : 600),
            duration: CMTime(value: dv, timescale: ds > 0 ? ds : 600))
        text = try c.decode(String.self, forKey: .text)
        words = try c.decodeIfPresent([WordTiming].self, forKey: .words)
        style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style)
        styleKeyframes = try c.decodeIfPresent(CaptionStyleKeyframes.self, forKey: .styleKeyframes)
    }

    public func encode(to encoder: any Encoder) throws {
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
        try c.encodeIfPresent(styleKeyframes, forKey: .styleKeyframes)
    }

    public var endTime: CMTime {
        let lineEnd = range.end
        let wordEnd = words?.reduce(CMTime.zero) { CMTimeMaximum($0, $1.range.end) } ?? .zero
        return CMTimeMaximum(lineEnd, wordEnd)
    }
}

// MARK: - Timeline Markers

/// The semantic role of a timeline marker.
public enum MarkerKind: String, Hashable, Codable, Sendable {
    /// A generic annotation marker (the default for legacy documents).
    case note
    /// A chapter marker used for YouTube sidecar and embedded chapter metadata.
    case chapter
}

public struct TimelineMarker: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var time: CMTime
    public var name: String
    public var colour: RGBAColour?
    /// The semantic kind of this marker. Defaults to `.note` for legacy
    /// documents that lack the field.
    public var kind: MarkerKind

    public init(id: UUID = UUID(), time: CMTime, name: String = "Marker",
                colour: RGBAColour? = nil, kind: MarkerKind = .note) {
        self.id = id
        self.time = time
        self.name = name
        self.colour = colour
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, time, name, colour, kind }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let timeCode = try c.decode(CMTimeCode.self, forKey: .time)
        time = timeCode.cmTime
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Marker"
        colour = try c.decodeIfPresent(RGBAColour.self, forKey: .colour)
        kind = try c.decodeIfPresent(MarkerKind.self, forKey: .kind) ?? .note
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeCode(time), forKey: .time)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(colour, forKey: .colour)
        try c.encode(kind, forKey: .kind)
    }
}

// MARK: - Audio

public struct TrackInput: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var pan: Float
    public var gain: Float

    public init(id: UUID, pan: Float = 0, gain: Float = 1) {
        self.id = id
        self.pan = pan
        self.gain = gain
    }

    public mutating func clamp() {
        pan = max(-1, min(1, pan))
        gain = max(0, min(2, gain))
    }
}

public enum VoiceCleanupInsertID: String, Hashable, Codable, CaseIterable, Sendable {
    case denoiser
    case gate
    case compressor
    case limiter

    public var displayName: String {
        switch self {
        case .denoiser: "Denoiser"
        case .gate: "Gate"
        case .compressor: "Compressor"
        case .limiter: "Limiter"
        }
    }
}

public enum LoudnessPreset: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case streaming
    case voice
    case broadcast
    case custom

    public var id: String { rawValue }

    public var targetLUFS: Float {
        switch self {
        case .streaming: -14
        case .voice: -16
        case .broadcast: -19
        case .custom: -14
        }
    }

    public var displayName: String {
        switch self {
        case .streaming: "-14 LUFS"
        case .voice: "-16 LUFS"
        case .broadcast: "-19 LUFS"
        case .custom: "Custom"
        }
    }
}

public struct DenoiserSettings: Hashable, Codable, Sendable {
    public var bypass: Bool
    public var reduction: Float
    public var noiseFloorDB: Float

    public init(bypass: Bool = true, reduction: Float = 0.45, noiseFloorDB: Float = -55) {
        self.bypass = bypass
        self.reduction = reduction
        self.noiseFloorDB = noiseFloorDB
        clamp()
    }

    // Lenient decode so adding fields in a later schema doesn't break loading
    // projects saved by this build (matches TrackDoc / ClipDoc / VolumeEnvelope).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bypass = try c.decodeIfPresent(Bool.self, forKey: .bypass) ?? true
        reduction = try c.decodeIfPresent(Float.self, forKey: .reduction) ?? 0.45
        noiseFloorDB = try c.decodeIfPresent(Float.self, forKey: .noiseFloorDB) ?? -55
        clamp()
    }

    public mutating func clamp() {
        reduction = max(0, min(1, reduction))
        noiseFloorDB = max(-90, min(-20, noiseFloorDB))
    }
}

public struct GateSettings: Hashable, Codable, Sendable {
    public var bypass: Bool
    public var thresholdDB: Float
    public var attackMS: Float
    public var releaseMS: Float
    public var rangeDB: Float

    public init(bypass: Bool = true,
                thresholdDB: Float = -40,
                attackMS: Float = 1,
                releaseMS: Float = 50,
                rangeDB: Float = -24) {
        self.bypass = bypass
        self.thresholdDB = thresholdDB
        self.attackMS = attackMS
        self.releaseMS = releaseMS
        self.rangeDB = rangeDB
        clamp()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bypass = try c.decodeIfPresent(Bool.self, forKey: .bypass) ?? true
        thresholdDB = try c.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? -40
        attackMS = try c.decodeIfPresent(Float.self, forKey: .attackMS) ?? 1
        releaseMS = try c.decodeIfPresent(Float.self, forKey: .releaseMS) ?? 50
        rangeDB = try c.decodeIfPresent(Float.self, forKey: .rangeDB) ?? -24
        clamp()
    }

    public mutating func clamp() {
        thresholdDB = max(-80, min(0, thresholdDB))
        attackMS = max(0.1, min(100, attackMS))
        releaseMS = max(1, min(1000, releaseMS))
        rangeDB = max(-80, min(0, rangeDB))
    }
}

public struct CompressorSettings: Hashable, Codable, Sendable {
    public var bypass: Bool
    public var thresholdDB: Float
    public var ratio: Float
    public var attackMS: Float
    public var releaseMS: Float
    public var makeupGainDB: Float

    public init(bypass: Bool = true,
                thresholdDB: Float = -18,
                ratio: Float = 3,
                attackMS: Float = 5,
                releaseMS: Float = 120,
                makeupGainDB: Float = 0) {
        self.bypass = bypass
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.attackMS = attackMS
        self.releaseMS = releaseMS
        self.makeupGainDB = makeupGainDB
        clamp()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bypass = try c.decodeIfPresent(Bool.self, forKey: .bypass) ?? true
        thresholdDB = try c.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? -18
        ratio = try c.decodeIfPresent(Float.self, forKey: .ratio) ?? 3
        attackMS = try c.decodeIfPresent(Float.self, forKey: .attackMS) ?? 5
        releaseMS = try c.decodeIfPresent(Float.self, forKey: .releaseMS) ?? 120
        makeupGainDB = try c.decodeIfPresent(Float.self, forKey: .makeupGainDB) ?? 0
        clamp()
    }

    public mutating func clamp() {
        thresholdDB = max(-60, min(0, thresholdDB))
        ratio = max(1, min(20, ratio))
        attackMS = max(0.1, min(200, attackMS))
        releaseMS = max(1, min(2000, releaseMS))
        makeupGainDB = max(-24, min(24, makeupGainDB))
    }
}

public struct LimiterSettings: Hashable, Codable, Sendable {
    public var bypass: Bool
    public var ceilingDB: Float
    public var releaseMS: Float

    public init(bypass: Bool = true, ceilingDB: Float = -1, releaseMS: Float = 50) {
        self.bypass = bypass
        self.ceilingDB = ceilingDB
        self.releaseMS = releaseMS
        clamp()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bypass = try c.decodeIfPresent(Bool.self, forKey: .bypass) ?? true
        ceilingDB = try c.decodeIfPresent(Float.self, forKey: .ceilingDB) ?? -1
        releaseMS = try c.decodeIfPresent(Float.self, forKey: .releaseMS) ?? 50
        clamp()
    }

    public mutating func clamp() {
        ceilingDB = max(-9, min(-0.1, ceilingDB))
        releaseMS = max(1, min(2000, releaseMS))
    }
}

public struct LoudnessNormalisationSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var preset: LoudnessPreset
    public var customTargetLUFS: Float
    public var measuredLUFS: Float?
    public var appliedGainDB: Float
    public var statusNote: String?

    public init(enabled: Bool = false,
                preset: LoudnessPreset = .streaming,
                customTargetLUFS: Float = -14,
                measuredLUFS: Float? = nil,
                appliedGainDB: Float = 0,
                statusNote: String? = nil) {
        self.enabled = enabled
        self.preset = preset
        self.customTargetLUFS = customTargetLUFS
        self.measuredLUFS = measuredLUFS
        self.appliedGainDB = appliedGainDB
        self.statusNote = statusNote
        clamp()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        preset = try c.decodeIfPresent(LoudnessPreset.self, forKey: .preset) ?? .streaming
        customTargetLUFS = try c.decodeIfPresent(Float.self, forKey: .customTargetLUFS) ?? -14
        measuredLUFS = try c.decodeIfPresent(Float.self, forKey: .measuredLUFS)
        appliedGainDB = try c.decodeIfPresent(Float.self, forKey: .appliedGainDB) ?? 0
        statusNote = try c.decodeIfPresent(String.self, forKey: .statusNote)
        clamp()
    }

    public var targetLUFS: Float {
        preset == .custom ? customTargetLUFS : preset.targetLUFS
    }

    /// Recomputes `appliedGainDB` from a previously measured loudness against the
    /// current `targetLUFS`. The measurement (program loudness) is independent of
    /// the target, so changing the preset/target should re-derive the gain rather
    /// than leave a stale value that renders to the old target. No-op when nothing
    /// has been measured, so a manually dialled-in gain is preserved.
    public mutating func refreshAppliedGainFromMeasurement() {
        guard let measuredLUFS, measuredLUFS.isFinite else { return }
        appliedGainDB = VoiceCleanupDSP.normalisationGain(
            measuredLUFS: measuredLUFS, targetLUFS: targetLUFS)
        enabled = appliedGainDB != 0
        clamp()
    }

    public mutating func clamp() {
        customTargetLUFS = max(-36, min(-6, customTargetLUFS))
        if let measuredLUFS, !measuredLUFS.isFinite {
            self.measuredLUFS = nil
        }
        appliedGainDB = max(-30, min(30, appliedGainDB))
        if let statusNote, statusNote.isEmpty {
            self.statusNote = nil
        }
    }
}

public struct VoiceCleanupSettings: Hashable, Codable, Sendable {
    public var denoiser: DenoiserSettings
    public var gate: GateSettings
    public var compressor: CompressorSettings
    public var limiter: LimiterSettings
    public var loudness: LoudnessNormalisationSettings

    public init(denoiser: DenoiserSettings = DenoiserSettings(),
                gate: GateSettings = GateSettings(),
                compressor: CompressorSettings = CompressorSettings(),
                limiter: LimiterSettings = LimiterSettings(),
                loudness: LoudnessNormalisationSettings = LoudnessNormalisationSettings()) {
        self.denoiser = denoiser
        self.gate = gate
        self.compressor = compressor
        self.limiter = limiter
        self.loudness = loudness
        clamp()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        denoiser = try c.decodeIfPresent(DenoiserSettings.self, forKey: .denoiser) ?? DenoiserSettings()
        gate = try c.decodeIfPresent(GateSettings.self, forKey: .gate) ?? GateSettings()
        compressor = try c.decodeIfPresent(CompressorSettings.self, forKey: .compressor) ?? CompressorSettings()
        limiter = try c.decodeIfPresent(LimiterSettings.self, forKey: .limiter) ?? LimiterSettings()
        loudness = try c.decodeIfPresent(LoudnessNormalisationSettings.self, forKey: .loudness) ?? LoudnessNormalisationSettings()
        clamp()
    }

    public static let insertOrder: [VoiceCleanupInsertID] = [.denoiser, .gate, .compressor, .limiter]

    /// Whether any DSP insert (denoiser, gate, compressor, limiter) is active.
    /// Loudness normalisation is a linear gain stage. It does **not** require
    /// the offline pipeline by itself: loudness-only preview/export can use the
    /// audio mix path, while DSP-active preview/export applies the gain inside
    /// the cleanup processor after the other inserts.
    public var requiresOfflineProcessing: Bool {
        !denoiser.bypass
            || !gate.bypass
            || !compressor.bypass
            || !limiter.bypass
    }

    /// The linear gain multiplier for loudness normalisation. Returns 1.0 when
    /// loudness is disabled or the applied gain is negligible.
    public var loudnessGainLinear: Float {
        guard loudness.enabled, abs(loudness.appliedGainDB) > 0.0001 else { return 1.0 }
        guard loudness.appliedGainDB.isFinite else { return 1.0 }
        return pow(10, loudness.appliedGainDB / 20)
    }

    public mutating func clamp() {
        denoiser.clamp()
        gate.clamp()
        compressor.clamp()
        limiter.clamp()
        loudness.clamp()
    }
}

public struct VolumeEnvelope: Hashable, Codable, Sendable {
    public struct Ramp: Hashable, Codable, Sendable {
        public var range: CMTimeRange
        public var fromVolume: Float
        public var toVolume: Float

        public init(range: CMTimeRange, fromVolume: Float, toVolume: Float) {
            self.range = range
            self.fromVolume = fromVolume
            self.toVolume = toVolume
        }

        private enum CodingKeys: String, CodingKey {
            case startValue, startScale, durationValue, durationScale, fromVolume, toVolume
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let sv = try c.decode(Int64.self, forKey: .startValue)
            let ss = try c.decode(Int32.self, forKey: .startScale)
            let dv = try c.decode(Int64.self, forKey: .durationValue)
            let ds = try c.decode(Int32.self, forKey: .durationScale)
            range = CMTimeRange(
                start: CMTime(value: sv, timescale: ss > 0 ? ss : 600),
                duration: CMTime(value: max(0, dv), timescale: ds > 0 ? ds : 600))
            fromVolume = try c.decodeIfPresent(Float.self, forKey: .fromVolume) ?? 1
            toVolume = try c.decodeIfPresent(Float.self, forKey: .toVolume) ?? 1
        }

        public func encode(to encoder: any Encoder) throws {
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

    public var fadeIn: CMTime
    public var fadeOut: CMTime
    public var ramps: [Ramp]

    public init(fadeIn: CMTime = .zero, fadeOut: CMTime = .zero, ramps: [Ramp] = []) {
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.ramps = ramps
    }

    public var isEmpty: Bool {
        fadeIn == .zero && fadeOut == .zero && ramps.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case fadeInValue, fadeInScale, fadeOutValue, fadeOutScale, ramps
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fiv = try c.decodeIfPresent(Int64.self, forKey: .fadeInValue) ?? 0
        let fis = try c.decodeIfPresent(Int32.self, forKey: .fadeInScale) ?? 600
        let fov = try c.decodeIfPresent(Int64.self, forKey: .fadeOutValue) ?? 0
        let fos = try c.decodeIfPresent(Int32.self, forKey: .fadeOutScale) ?? 600
        fadeIn = CMTime(value: fiv, timescale: fis > 0 ? fis : 600)
        fadeOut = CMTime(value: fov, timescale: fos > 0 ? fos : 600)
        ramps = try c.decodeIfPresent([Ramp].self, forKey: .ramps) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let fi = fadeIn.isNumeric ? fadeIn : .zero
        let fo = fadeOut.isNumeric ? fadeOut : .zero
        try c.encode(fi.value, forKey: .fadeInValue)
        try c.encode(fi.timescale == 0 ? 600 : fi.timescale, forKey: .fadeInScale)
        try c.encode(fo.value, forKey: .fadeOutValue)
        try c.encode(fo.timescale == 0 ? 600 : fo.timescale, forKey: .fadeOutScale)
        if !ramps.isEmpty { try c.encode(ramps, forKey: .ramps) }
    }

    public func clampedFades(clipDuration: CMTime) -> (fadeIn: CMTime, fadeOut: CMTime) {
        guard clipDuration > .zero else { return (.zero, .zero) }
        let fi = CMTimeMaximum(.zero, CMTimeMinimum(fadeIn, clipDuration))
        let fo = CMTimeMaximum(.zero, CMTimeMinimum(fadeOut, clipDuration))
        let sum = fi + fo
        if sum <= clipDuration { return (fi, fo) }
        let half = CMTimeMultiplyByRatio(clipDuration, multiplier: 1, divisor: 2)
        return (half, half)
    }

    public static func clampedRange(_ range: CMTimeRange, to clipRange: CMTimeRange) -> CMTimeRange? {
        let intersection = range.intersection(clipRange)
        return intersection.duration > .zero ? intersection : nil
    }
}

public struct AudioMeterSnapshot: Hashable, Sendable {
    public var peakLeft: Float
    public var peakRight: Float
    public var rmsLeft: Float
    public var rmsRight: Float
    public var sampledAt: ContinuousClock.Instant

    public init(peakLeft: Float, peakRight: Float, rmsLeft: Float, rmsRight: Float,
                sampledAt: ContinuousClock.Instant) {
        self.peakLeft = peakLeft
        self.peakRight = peakRight
        self.rmsLeft = rmsLeft
        self.rmsRight = rmsRight
        self.sampledAt = sampledAt
    }

    /// A fresh silent snapshot with the current timestamp. Returns a new instance
    /// on each access so `sampledAt` is never stale.
    public static var silent: AudioMeterSnapshot {
        AudioMeterSnapshot(
            peakLeft: 0, peakRight: 0, rmsLeft: 0, rmsRight: 0,
            sampledAt: ContinuousClock.now)
    }
}

// MARK: - Animated Overlays (Phase 38b)

/// The source type for an animated overlay clip.
public enum OverlaySourceType: String, Hashable, Codable, Sendable, CaseIterable, Identifiable {
    /// Animated image (WebP, GIF, APNG) decoded frame-by-frame via ImageIO.
    case animatedImage
    /// Lottie JSON animation rendered off-screen to CIImage per frame.
    case lottie
    /// Video file with a premultiplied alpha channel.
    case alphaVideo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .animatedImage: "Animated Image"
        case .lottie: "Lottie"
        case .alphaVideo: "Alpha Video"
        }
    }
}

/// Playback behaviour when an overlay clip reaches the end of its source media.
public enum OverlayEndAction: String, Hashable, Codable, Sendable, CaseIterable, Identifiable {
    /// Hide the overlay (render nothing past the end).
    case hide
    /// Freeze on the last frame.
    case freeze
    /// Loop back to the first frame.
    case loop

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hide: "Hide"
        case .freeze: "Freeze"
        case .loop: "Loop"
        }
    }
}

/// An animated overlay clip placed on the timeline. Overlays sit above the
/// video track stack and composite in order. Each clip references an overlay
/// source file and carries its own timing, transform, and opacity.
public struct OverlayClip: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The type of source media.
    public var sourceType: OverlaySourceType
    /// Timeline start time.
    public var timelineStart: CMTime
    /// Timeline duration (how long the overlay is visible).
    public var duration: CMTime
    /// 2D position offset from the render canvas centre, in normalised
    /// coordinates (−1…1 where 1 = canvas width/height). Used as the static
    /// default when `positionKeyframes` has no authored keyframes.
    public var positionOffset: CGSize
    /// Uniform scale factor (1 = original size). Used as the static default
    /// when `scaleKeyframes` has no authored keyframes.
    public var scale: CGFloat
    /// Rotation in radians. Used as the static default when
    /// `rotationKeyframes` has no authored keyframes.
    public var rotation: CGFloat
    /// Per-overlay opacity (0…1). Used as the static default when
    /// `opacityKeyframes` has no authored keyframes.
    public var opacity: Float
    /// What to do when the source animation reaches its end.
    public var endAction: OverlayEndAction

    // MARK: - Keyframed animation tracks

    /// Keyframed position X (normalised -1…1). When empty, `positionOffset.width` is used.
    public var positionXKeyframes: Keyframed<Float>
    /// Keyframed position Y (normalised -1…1). When empty, `positionOffset.height` is used.
    public var positionYKeyframes: Keyframed<Float>
    /// Keyframed scale. When empty, `scale` is used.
    public var scaleKeyframes: Keyframed<Float>
    /// Keyframed rotation (radians). When empty, `rotation` is used.
    public var rotationKeyframes: Keyframed<Float>
    /// Keyframed opacity (0…1). When empty, `opacity` is used.
    public var opacityKeyframes: Keyframed<Float>

    /// Whether any animation track has authored keyframes.
    public var isAnimated: Bool {
        !positionXKeyframes.keyframes.isEmpty
            || !positionYKeyframes.keyframes.isEmpty
            || !scaleKeyframes.keyframes.isEmpty
            || !rotationKeyframes.keyframes.isEmpty
            || !opacityKeyframes.keyframes.isEmpty
    }

    public var timelineEnd: CMTime { timelineStart + duration }

    public init(id: UUID = UUID(),
                sourceType: OverlaySourceType,
                timelineStart: CMTime,
                duration: CMTime,
                positionOffset: CGSize = .zero,
                scale: CGFloat = 1,
                rotation: CGFloat = 0,
                opacity: Float = 1,
                endAction: OverlayEndAction = .loop,
                positionXKeyframes: Keyframed<Float> = Keyframed(defaultValue: 0),
                positionYKeyframes: Keyframed<Float> = Keyframed(defaultValue: 0),
                scaleKeyframes: Keyframed<Float> = Keyframed(defaultValue: 1),
                rotationKeyframes: Keyframed<Float> = Keyframed(defaultValue: 0),
                opacityKeyframes: Keyframed<Float> = Keyframed(defaultValue: 1)) {
        self.id = id
        self.sourceType = sourceType
        self.timelineStart = timelineStart
        self.duration = duration
        self.positionOffset = positionOffset
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.endAction = endAction
        self.positionXKeyframes = positionXKeyframes
        self.positionYKeyframes = positionYKeyframes
        self.scaleKeyframes = scaleKeyframes
        self.rotationKeyframes = rotationKeyframes
        self.opacityKeyframes = opacityKeyframes
    }

    /// Returns the effective transform values at the given overlay-local time,
    /// interpolating keyframes when animated, falling back to static values otherwise.
    public func transform(at localTime: CMTime) -> OverlayTransform {
        OverlayTransform(
            positionX: positionXKeyframes.isAnimated
                ? positionXKeyframes.value(at: localTime)
                : Float(positionOffset.width),
            positionY: positionYKeyframes.isAnimated
                ? positionYKeyframes.value(at: localTime)
                : Float(positionOffset.height),
            scale: scaleKeyframes.isAnimated
                ? CGFloat(scaleKeyframes.value(at: localTime))
                : scale,
            rotation: rotationKeyframes.isAnimated
                ? CGFloat(rotationKeyframes.value(at: localTime))
                : rotation,
            opacity: opacityKeyframes.isAnimated
                ? opacityKeyframes.value(at: localTime)
                : opacity)
    }
}

/// Interpolated overlay transform values at a point in time.
public nonisolated struct OverlayTransform: Sendable {
    public var positionX: Float
    public var positionY: Float
    public var scale: CGFloat
    public var rotation: CGFloat
    public var opacity: Float

    public nonisolated init(positionX: Float, positionY: Float, scale: CGFloat, rotation: CGFloat, opacity: Float) {
        self.positionX = positionX
        self.positionY = positionY
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
    }
}
