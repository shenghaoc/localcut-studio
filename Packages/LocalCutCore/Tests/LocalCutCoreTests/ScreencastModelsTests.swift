import Testing
import Foundation
import CoreMedia
import CoreGraphics
@testable import LocalCutCore

// MARK: - Transform2D

@Suite("Transform2D interpolation and Codable")
struct Transform2DTests {
    @Test("Identity round-trips through lerp with t=0 and t=1")
    func identityLerp() {
        let a = Transform2D.identity
        let b = Transform2D(a: 2, b: 0, c: 0, d: 2, tx: 100, ty: 200)
        #expect(Transform2D.lerp(a, b, t: 0) == a)
        let lerped = Transform2D.lerp(a, b, t: 1)
        #expect(abs(lerped.a - 2) < 0.001)
        #expect(abs(lerped.tx - 100) < 0.001)
    }

    @Test("Midpoint lerp produces expected values")
    func midpointLerp() {
        let a = Transform2D.identity
        let b = Transform2D(a: 2, b: 0, c: 0, d: 2, tx: 100, ty: 0)
        let mid = Transform2D.lerp(a, b, t: 0.5)
        #expect(abs(mid.a - 1.5) < 0.001)
        #expect(abs(mid.tx - 50) < 0.001)
    }

    @Test("Decomposed scale and rotation round-trip")
    func decomposedScaleRotation() {
        let t = Transform2D(translateX: 10, translateY: 20, scale: 2, rotation: .pi / 4)
        #expect(abs(t.decomposedScale - 2) < 0.01)
        #expect(abs(t.decomposedRotation - Float.pi / 4) < 0.01)
        let (dx, dy) = t.decomposedTranslation
        #expect(abs(dx - 10) < 0.01)
        #expect(abs(dy - 20) < 0.01)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let original = Transform2D(translateX: 50, translateY: -30, scale: 1.5, rotation: 0.3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transform2D.self, from: data)
        #expect(abs(decoded.a - original.a) < 0.001)
        #expect(abs(decoded.tx - original.tx) < 0.001)
    }

    @Test("CGAffineTransform conversion round-trip")
    func cgTransformConversion() {
        let t = Transform2D(translateX: 10, translateY: 20, scale: 1.5, rotation: 0)
        let cg = t.cgTransform
        let back = Transform2D(cg)
        #expect(abs(back.tx - t.tx) < 0.001)
        #expect(abs(back.ty - t.ty) < 0.001)
    }
}

// MARK: - ScreencastEventLog

@Suite("ScreencastEventLog Codable and schema")
struct ScreencastEventLogTests {
    @Test("Round-trip encode/decode preserves events")
    func roundTrip() throws {
        let log = ScreencastEventLog(
            schemaVersion: 1,
            sessionID: UUID(),
            events: [
                ScreencastEvent(time: CMTime(seconds: 1, preferredTimescale: 600),
                                kind: .mouseDown,
                                position: CGPoint(x: 100, y: 200)),
                ScreencastEvent(time: CMTime(seconds: 2, preferredTimescale: 600),
                                kind: .key,
                                keyCode: 36,
                                modifierFlagsRaw: 0x100000),
                ScreencastEvent(time: CMTime(seconds: 3, preferredTimescale: 600),
                                kind: .scroll,
                                position: CGPoint(x: 500, y: 300)),
            ])
        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(ScreencastEventLog.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.events.count == 3)
        #expect(decoded.events[0].kind == .mouseDown)
        #expect(decoded.events[1].keyCode == 36)
        #expect(decoded.events[2].kind == .scroll)
    }

    @Test("Supported schema version is detected")
    func supportedSchema() {
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: [])
        #expect(log.isSupportedSchema)
    }

    @Test("Unsupported schema version is detected")
    func unsupportedSchema() {
        let log = ScreencastEventLog(schemaVersion: 99, sessionID: UUID(), events: [])
        #expect(!log.isSupportedSchema)
    }

    @Test("Empty event list is valid")
    func emptyEvents() throws {
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: [])
        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(ScreencastEventLog.self, from: data)
        #expect(decoded.events.isEmpty)
    }
}

// MARK: - ZoomPanPreset

@Suite("ZoomPanPreset model")
struct ZoomPanPresetTests {
    @Test("Default values are valid")
    func defaults() {
        let preset = ZoomPanPreset(kind: .slowZoomIn)
        #expect(preset.kind == .slowZoomIn)
        #expect(preset.endScale >= 1.0)
        #expect(preset.endScale <= 5.0)
    }

    @Test("Scale is clamped to valid range")
    func scaleClamped() {
        let low = ZoomPanPreset(kind: .pan, endScale: 0.1)
        #expect(low.endScale >= 1.0)
        let high = ZoomPanPreset(kind: .pan, endScale: 100)
        #expect(high.endScale <= 5.0)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let preset = ZoomPanPreset(kind: .snapZoomOnClick,
                                   targetPoint: CGPoint(x: 0.3, y: 0.7),
                                   endScale: 2.5,
                                   duration: CMTime(seconds: 5, preferredTimescale: 600))
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(ZoomPanPreset.self, from: data)
        #expect(decoded.kind == .snapZoomOnClick)
        #expect(abs(decoded.endScale - 2.5) < 0.001)
    }
}

// MARK: - CalloutClip

@Suite("CalloutClip model")
struct CalloutClipTests {
    @Test("Each callout kind can be created with defaults")
    func allKindsHaveDefaults() {
        for kind in CalloutKind.allCases {
            let clip = CalloutClip(kind: kind,
                                   timeRange: CMTimeRange(start: .zero,
                                                          duration: CMTime(seconds: 2, preferredTimescale: 600)))
            #expect(clip.kind == kind)
            #expect(clip.scale >= 0.1)
        }
    }

    @Test("Step number increment")
    func stepNumberIncrement() {
        let clip = CalloutClip(kind: .stepNumber,
                               timeRange: CMTimeRange(start: .zero,
                                                      duration: CMTime(seconds: 2, preferredTimescale: 600)),
                               stepNumber: 3)
        let next = clip.withNextStepNumber()
        #expect(next.stepNumber == 4)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let clip = CalloutClip(kind: .arrow,
                               timeRange: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                                                      duration: CMTime(seconds: 3, preferredTimescale: 600)),
                               startPoint: CGPoint(x: 0.1, y: 0.2),
                               endPoint: CGPoint(x: 0.9, y: 0.8),
                               arrowStyle: ArrowCalloutStyle(strokeWidth: 5))
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(CalloutClip.self, from: data)
        #expect(decoded.kind == .arrow)
        #expect(decoded.arrowStyle.strokeWidth == 5)
        #expect(abs(decoded.startPoint.x - 0.1) < 0.001)
    }
}

// MARK: - PaddedBackgroundPreset

@Suite("PaddedBackgroundPreset model")
struct PaddedBackgroundPresetTests {
    @Test("Defaults produce valid preset")
    func defaults() {
        let preset = PaddedBackgroundPreset()
        #expect(preset.source == .gradient)
        #expect(preset.cornerRadius >= 0)
        #expect(preset.shadowOpacity >= 0)
        #expect(preset.shadowOpacity <= 1)
        #expect(preset.insetMargin >= 0)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let preset = PaddedBackgroundPreset(
            source: .gradient,
            gradientStart: SIMD4(0.2, 0.3, 0.4, 1),
            gradientEnd: SIMD4(0.1, 0.1, 0.1, 1),
            cornerRadius: 20,
            shadowOpacity: 0.6,
            shadowRadius: 15,
            insetMargin: 50)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(PaddedBackgroundPreset.self, from: data)
        #expect(decoded.source == .gradient)
        #expect(abs(decoded.cornerRadius - 20) < 0.001)
        #expect(abs(decoded.shadowOpacity - 0.6) < 0.001)
    }
}

// MARK: - Velocity / Acceleration Bounds

@Suite("ZoomPanBounds constants")
struct ZoomPanBoundsTests {
    @Test("Bounds are positive and finite")
    func boundsPositive() {
        #expect(ZoomPanBounds.maxVelocity > 0)
        #expect(ZoomPanBounds.maxScaleVelocity > 0)
        #expect(ZoomPanBounds.maxAcceleration > 0)
        #expect(ZoomPanBounds.maxScaleAcceleration > 0)
    }
}
