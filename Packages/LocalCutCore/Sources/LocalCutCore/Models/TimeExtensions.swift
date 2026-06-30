import Foundation
import CoreMedia
import CoreGraphics

// MARK: - Metadata Sanitization

extension CMTime {
    /// A generous upper bound (in seconds) for a trusted media duration. Values
    /// beyond this are treated as corrupt: they serve no legitimate editing
    /// purpose and would later trap `Int(seconds)` in timecode formatting.
    private static let maxSaneSeconds: Double = 100 * 60 * 60   // 100 hours

    /// Returns a validated time, falling back to `.zero` if the time is invalid,
    /// indefinite, infinite, negative, or implausibly large (any of which could
    /// corrupt geometry/time math or trap downstream timecode conversion).
    public var sanitized: CMTime {
        guard isValid, !isIndefinite, !isPositiveInfinity, !isNegativeInfinity,
              self >= .zero, seconds.isFinite, seconds <= CMTime.maxSaneSeconds else {
            return .zero
        }
        return self
    }
}

extension CGSize {
    /// Upper bound (in pixels) for a plausible media dimension. Beyond this,
    /// values are treated as corrupt.
    private static let maxSanePixels: CGFloat = 100_000   // well past 8K

    /// Returns a validated size, falling back to `.zero` if non-finite, and
    /// clamping each dimension into `0...maxSanePixels`.
    public var sanitized: CGSize {
        guard width.isFinite, height.isFinite else { return .zero }
        func clamp(_ v: CGFloat) -> CGFloat { min(max(0, v), CGSize.maxSanePixels) }
        return CGSize(width: clamp(width), height: clamp(height))
    }
}

extension CGAffineTransform {
    /// Upper bound on the magnitude of any transform coefficient.
    private static let maxSaneCoefficient: CGFloat = 1_000_000

    /// Returns a validated transform, falling back to `.identity` if any
    /// component is non-finite or implausibly large.
    public var sanitized: CGAffineTransform {
        func ok(_ v: CGFloat) -> Bool { v.isFinite && abs(v) <= CGAffineTransform.maxSaneCoefficient }
        guard ok(a), ok(b), ok(c), ok(d), ok(tx), ok(ty) else { return .identity }
        return self
    }
}

// MARK: - CMTime Codable wrapper

/// Lossless `CMTime` representation: a rational `value/timescale` pair so timeline
/// math round-trips exactly (a `Double` of seconds would not).
public struct CMTimeCode: Codable, Equatable, Sendable {
    public var value: Int64
    public var timescale: Int32

    public init(_ time: CMTime) {
        if time.isNumeric, time.timescale > 0 {
            self.value = time.value
            self.timescale = time.timescale
        } else {
            self.value = 0
            self.timescale = 600
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(Int64.self, forKey: .value)
        let rawTimescale = try container.decode(Int32.self, forKey: .timescale)
        if rawTimescale > 0 {
            self.value = rawValue
            self.timescale = rawTimescale
        } else {
            self.value = 0
            self.timescale = 600
        }
    }

    public var cmTime: CMTime {
        // The stored fields are public for Codable/model compatibility, so keep
        // this conversion defensive even though our initializers normalize them.
        guard timescale > 0 else { return .zero }
        return CMTime(value: value, timescale: timescale)
    }
}

// MARK: - CGAffineTransform Codable wrapper

/// Codable form of an affine transform (the media's preferred orientation).
public struct TransformCode: Codable, Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(_ t: CGAffineTransform) {
        a = t.a; b = t.b; c = t.c; d = t.d; tx = t.tx; ty = t.ty
    }

    public var cgTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

// MARK: - Interpolation protocol

/// A type that can be linearly interpolated between two values.
public protocol Interpolatable: Hashable, Codable, Sendable {
    static func lerp(_ a: Self, _ b: Self, t: Float) -> Self
}

extension Float: Interpolatable {
    public static func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }
}

/// A 2-D affine transform stored as six `Float` components, conforming to
/// `Interpolatable` so it can be used with `Keyframed<Transform2D>` for
/// zoom-n-pan and callout transform animation.
///
/// Interpolation is component-wise (matrix lerp). This is exact for
/// translation-only and scale-only segments; for rotations the result
/// approximates the shortest arc — acceptable at typical screencast
/// zoom/pan magnitudes.
public struct Transform2D: Hashable, Codable, Sendable {
    public var a: Float
    public var b: Float
    public var c: Float
    public var d: Float
    public var tx: Float
    public var ty: Float

    public static let identity = Transform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public init(_ t: CGAffineTransform) {
        a = Float(t.a); b = Float(t.b); c = Float(t.c)
        d = Float(t.d); tx = Float(t.tx); ty = Float(t.ty)
    }

    /// Build a transform from decomposed parameters: translation, uniform
    /// scale, and rotation (radians). Shear is not represented.
    public init(translateX: Float, translateY: Float, scale: Float, rotation: Float) {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        a = scale * cosR
        b = scale * sinR
        c = -scale * sinR
        d = scale * cosR
        tx = translateX
        ty = translateY
    }

    public var cgTransform: CGAffineTransform {
        CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c),
                          d: CGFloat(d), tx: CGFloat(tx), ty: CGFloat(ty))
    }

    /// Decomposed uniform scale (geometric mean of the two axis scales).
    public var decomposedScale: Float {
        sqrt(max(0, a * a + b * b))
    }

    /// Decomposed rotation in radians.
    public var decomposedRotation: Float {
        atan2(b, a)
    }

    /// Decomposed translation.
    public var decomposedTranslation: (x: Float, y: Float) { (tx, ty) }
}

extension Transform2D: Interpolatable {
    public static func lerp(_ lhs: Transform2D, _ rhs: Transform2D, t: Float) -> Transform2D {
        Transform2D(a: lhs.a + (rhs.a - lhs.a) * t,
                    b: lhs.b + (rhs.b - lhs.b) * t,
                    c: lhs.c + (rhs.c - lhs.c) * t,
                    d: lhs.d + (rhs.d - lhs.d) * t,
                    tx: lhs.tx + (rhs.tx - lhs.tx) * t,
                    ty: lhs.ty + (rhs.ty - lhs.ty) * t)
    }
}
