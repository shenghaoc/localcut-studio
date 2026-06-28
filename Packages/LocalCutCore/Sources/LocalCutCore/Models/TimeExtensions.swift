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
        if time.isNumeric {
            self.value = time.value
            self.timescale = time.timescale
        } else {
            self.value = 0
            self.timescale = 600
        }
    }

    public var cmTime: CMTime {
        // A nonpositive timescale is always corrupt metadata; return an invalid
        // CMTime so downstream `.sanitized` rejects it rather than silently
        // rewriting the timescale and accepting a bogus duration.
        guard timescale > 0 else {
            return CMTime(value: 0, timescale: 0) // invalid
        }
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
