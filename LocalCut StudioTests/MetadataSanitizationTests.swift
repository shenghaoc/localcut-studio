import Testing
import Foundation
import AVFoundation
import CoreGraphics
import LocalCutCore
@testable import LocalCut_Studio

/// Validates the `.sanitized` guards applied to untrusted media metadata at the
/// `AVAsset` ingestion boundary (duration, natural size, preferred transform).
@Suite("Metadata Sanitization")
struct MetadataSanitizationTests {

    // MARK: - CMTime

    @Test("Valid finite duration passes through unchanged")
    func cmTimePassesValid() {
        let t = CMTime(value: 1001, timescale: 30_000)
        #expect(t.sanitized == t)
    }

    @Test("Invalid / indefinite / infinite durations collapse to zero")
    func cmTimeRejectsNonNumeric() {
        #expect(CMTime.invalid.sanitized == .zero)
        #expect(CMTime.indefinite.sanitized == .zero)
        #expect(CMTime.positiveInfinity.sanitized == .zero)
        #expect(CMTime.negativeInfinity.sanitized == .zero)
    }

    @Test("Negative time collapses to zero, including via a negative timescale")
    func cmTimeRejectsNegative() {
        #expect(CMTime(value: -5, timescale: 600).sanitized == .zero)
        // A positive value with a negative timescale is a negative time; the
        // `value >= 0` shortcut would wrongly accept it, `self >= .zero` rejects it.
        #expect(CMTime(value: 5, timescale: -600).sanitized == .zero)
    }

    @Test("Implausibly large finite duration collapses to zero")
    func cmTimeRejectsEnormous() {
        // Would otherwise trap `Int(seconds)` in timecode formatting.
        #expect(CMTime(value: Int64.max, timescale: 1).sanitized == .zero)
    }

    // MARK: - CGSize

    @Test("Valid finite size passes through unchanged")
    func sizePassesValid() {
        let s = CGSize(width: 1920, height: 1080)
        #expect(s.sanitized == s)
    }

    @Test("Non-finite size collapses to zero")
    func sizeRejectsNonFinite() {
        #expect(CGSize(width: CGFloat.nan, height: 1080).sanitized == .zero)
        #expect(CGSize(width: 1920, height: CGFloat.infinity).sanitized == .zero)
    }

    @Test("Negative dimensions clamp to zero")
    func sizeClampsNegative() {
        #expect(CGSize(width: -1920, height: -1080).sanitized == .zero)
    }

    @Test("Mixed-sign dimensions clamp only the negative axis to zero")
    func sizeClampsMixedSign() {
        #expect(CGSize(width: 1920, height: -1080).sanitized == CGSize(width: 1920, height: 0))
    }

    @Test("Implausibly large finite dimensions clamp to the sane maximum")
    func sizeClampsEnormous() {
        // Would otherwise trap `Int(width)` in the inspector.
        let clamped = CGSize(width: 1e100, height: 1e100).sanitized
        #expect(clamped.width.isFinite)
        #expect(clamped.height.isFinite)
        #expect(Int(clamped.width) > 0)   // no trap, finite, usable
    }

    // MARK: - CGAffineTransform

    @Test("Valid finite transform passes through unchanged")
    func transformPassesValid() {
        let t = CGAffineTransform(rotationAngle: 1.2)
        #expect(t.sanitized == t)
    }

    @Test("Non-finite transform component collapses to identity")
    func transformRejectsNonFinite() {
        var t = CGAffineTransform.identity
        t.tx = .nan
        #expect(t.sanitized == .identity)
    }

    @Test("Implausibly large finite coefficient collapses to identity")
    func transformRejectsEnormous() {
        // Would otherwise overflow oriented bounds to infinity during frame fitting.
        let t = CGAffineTransform(a: 1e30, b: 0, c: 0, d: 1e30, tx: 0, ty: 0)
        #expect(t.sanitized == .identity)
    }
}
