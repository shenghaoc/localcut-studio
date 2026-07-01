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

    @Test("Image bundle path round-trips")
    func imageBundlePathRoundTrip() throws {
        let preset = PaddedBackgroundPreset(
            source: .image,
            imageBookmark: Data([0x01, 0x02]),
            imageBundleRelativePath: "assets/background.png")
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(PaddedBackgroundPreset.self, from: data)

        #expect(decoded.source == .image)
        #expect(decoded.imageBookmark == Data([0x01, 0x02]))
        #expect(decoded.imageBundleRelativePath == "assets/background.png")
    }
}

// MARK: - Velocity / Acceleration Bounds

@Suite("ZoomPanBounds constants")
struct ZoomPanBoundsTests {
    @Test("Bounds are positive and finite")
    func boundsPositive() {
        #expect(ZoomPanBounds.maxVelocity > 0)
        #expect(ZoomPanBounds.referenceRenderWidth > 0)
        #expect(ZoomPanBounds.maxScaleVelocity > 0)
        #expect(ZoomPanBounds.maxAcceleration > 0)
        #expect(ZoomPanBounds.maxScaleAcceleration > 0)
    }
}

// MARK: - ZoomPanPresetGenerator

@Suite("ZoomPanPresetGenerator")
struct ZoomPanPresetGeneratorTests {
    let clipDuration = CMTime(seconds: 10, preferredTimescale: 600)

    @Test("Slow zoom-in produces two keyframes")
    func slowZoomInKeyframes() {
        let preset = ZoomPanPreset(kind: .slowZoomIn, endScale: 2, duration: clipDuration)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: clipDuration)
        #expect(keyframes.count == 2)
        #expect(keyframes[0].value == .identity)
        #expect(keyframes[1].value.decomposedScale > 1)
    }

    @Test("Pan produces two keyframes with different translations")
    func panKeyframes() {
        let preset = ZoomPanPreset(kind: .pan, endScale: 1.5, duration: clipDuration)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: clipDuration)
        #expect(keyframes.count == 2)
        #expect(keyframes[0].value.tx != keyframes[1].value.tx)
    }

    @Test("Snap zoom produces four keyframes")
    func snapZoomKeyframes() {
        let preset = ZoomPanPreset(kind: .snapZoomOnClick, endScale: 2.5, duration: clipDuration)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: clipDuration)
        #expect(keyframes.count == 4)
        // Start and end at identity
        #expect(keyframes[0].value == .identity)
        #expect(keyframes[3].value == .identity)
        // Middle two at zoomed scale
        #expect(keyframes[1].value.decomposedScale > 1)
        #expect(keyframes[2].value.decomposedScale > 1)
    }

    @Test("Snap zoom preserves terminal identity on short clips")
    func shortSnapZoomEndsAtIdentity() {
        let shortDuration = CMTime(seconds: 0.2, preferredTimescale: 600)
        let preset = ZoomPanPreset(
            kind: .snapZoomOnClick,
            targetPoint: CGPoint(x: 0.25, y: 0.25),
            endScale: 4,
            duration: shortDuration)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: shortDuration)
        #expect(keyframes.last?.value == .identity)
    }

    @Test("Keyframe times are sorted")
    func keyframesSorted() {
        let preset = ZoomPanPreset(kind: .snapZoomOnClick, endScale: 2, duration: clipDuration)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: clipDuration)
        for i in 1..<keyframes.count {
            #expect(keyframes[i].time >= keyframes[i - 1].time)
        }
    }

    @Test("Velocity bounds are enforced")
    func velocityBoundsEnforced() {
        // Create a preset that would exceed velocity bounds
        let shortDuration = CMTime(seconds: 0.1, preferredTimescale: 600)
        let preset = ZoomPanPreset(
            kind: .slowZoomIn,
            targetPoint: CGPoint(x: 0, y: 0),
            endScale: 5,
            duration: shortDuration)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: clipDuration)
        // Should still produce valid keyframes (bounds enforcement adjusts values)
        #expect(keyframes.count == 2)
        let dt = keyframes[1].time.seconds - keyframes[0].time.seconds
        guard dt > 0 else { return }
        let dx = keyframes[1].value.tx - keyframes[0].value.tx
        let dy = keyframes[1].value.ty - keyframes[0].value.ty
        let velocity = sqrt(dx * dx + dy * dy) * ZoomPanBounds.referenceRenderWidth / Float(dt)
        #expect(velocity <= ZoomPanBounds.maxVelocity + 0.01)
    }

    @Test("Empty result for zero duration")
    func zeroDuration() {
        let preset = ZoomPanPreset(kind: .slowZoomIn, duration: .zero)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: clipDuration)
        #expect(keyframes.isEmpty)
    }

    @Test("Duration is clamped to clip duration")
    func durationClamped() {
        let longDuration = CMTime(seconds: 100, preferredTimescale: 600)
        let preset = ZoomPanPreset(kind: .slowZoomIn, duration: longDuration)
        let keyframes = ZoomPanPresetGenerator.generateKeyframes(for: preset, clipDuration: clipDuration)
        // Last keyframe should be at clip duration, not 100s
        if let last = keyframes.last {
            #expect(last.time.seconds <= clipDuration.seconds + 0.01)
        }
    }
}

// MARK: - AutoZoomProposalGenerator

@Suite("AutoZoomProposalGenerator")
struct AutoZoomProposalGeneratorTests {
    let canvasSize = CGSize(width: 1920, height: 1080)

    @Test("Empty event log produces no proposals")
    func emptyLog() {
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: [])
        let proposals = AutoZoomProposalGenerator.generateProposals(from: log, canvasSize: canvasSize)
        #expect(proposals.isEmpty)
    }

    @Test("Unsupported schema produces no proposals")
    func unsupportedSchema() {
        let log = ScreencastEventLog(schemaVersion: 99, sessionID: UUID(), events: [
            ScreencastEvent(time: CMTime(seconds: 1, preferredTimescale: 600),
                            kind: .mouseDown,
                            position: CGPoint(x: 0.5, y: 0.5))
        ])
        let proposals = AutoZoomProposalGenerator.generateProposals(from: log, canvasSize: canvasSize)
        #expect(proposals.isEmpty)
    }

    @Test("Click bursts cluster consistently")
    func clickBurstClustering() {
        // Positions are normalised 0...1 (as stored by ScreencastEventLogWriter).
        let events = [
            ScreencastEvent(time: CMTime(seconds: 1, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.26, y: 0.28)),
            ScreencastEvent(time: CMTime(seconds: 1.3, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.27, y: 0.29)),
            ScreencastEvent(time: CMTime(seconds: 1.6, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.26, y: 0.28)),
            // Long gap — new burst at a distant point
            ScreencastEvent(time: CMTime(seconds: 5, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.7, y: 0.6)),
            ScreencastEvent(time: CMTime(seconds: 5.2, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.71, y: 0.61)),
        ]
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: events)
        let proposals = AutoZoomProposalGenerator.generateProposals(from: log, canvasSize: canvasSize)
        #expect(proposals.count == 2)
        #expect(proposals[0].clickCount == 3)
        #expect(proposals[1].clickCount == 2)
    }

    @Test("Deterministic output for same fixture log")
    func determinism() {
        let events = [
            ScreencastEvent(time: CMTime(seconds: 1, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.5, y: 0.5)),
            ScreencastEvent(time: CMTime(seconds: 1.2, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.51, y: 0.51)),
            ScreencastEvent(time: CMTime(seconds: 1.4, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.505, y: 0.505)),
        ]
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: events)
        let proposals1 = AutoZoomProposalGenerator.generateProposals(from: log, canvasSize: canvasSize)
        let proposals2 = AutoZoomProposalGenerator.generateProposals(from: log, canvasSize: canvasSize)
        #expect(proposals1.count == proposals2.count)
        for (p1, p2) in zip(proposals1, proposals2) {
            #expect(p1.targetPoint == p2.targetPoint)
            #expect(p1.keyframes.count == p2.keyframes.count)
        }
    }

    @Test("Scroll/key events do not create click zoom proposals")
    func nonClickEventsIgnored() {
        let events = [
            ScreencastEvent(time: CMTime(seconds: 1, preferredTimescale: 600),
                            kind: .scroll, position: CGPoint(x: 0.5, y: 0.5)),
            ScreencastEvent(time: CMTime(seconds: 1.2, preferredTimescale: 600),
                            kind: .key, keyCode: 36, modifierFlagsRaw: 0x100000),
        ]
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: events)
        let proposals = AutoZoomProposalGenerator.generateProposals(from: log, canvasSize: canvasSize)
        #expect(proposals.isEmpty)
    }

    @Test("Single click does not create proposal (below minClicksForBurst)")
    func singleClickIgnored() {
        let events = [
            ScreencastEvent(time: CMTime(seconds: 1, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.5, y: 0.5)),
        ]
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: events)
        let proposals = AutoZoomProposalGenerator.generateProposals(from: log, canvasSize: canvasSize)
        #expect(proposals.isEmpty)
    }

    @Test("Proposal has expected keyframe count")
    func proposalKeyframes() {
        let events = [
            ScreencastEvent(time: CMTime(seconds: 1, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.5, y: 0.5)),
            ScreencastEvent(time: CMTime(seconds: 1.2, preferredTimescale: 600),
                            kind: .mouseDown, position: CGPoint(x: 0.51, y: 0.51)),
        ]
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: events)
        let proposals = AutoZoomProposalGenerator.generateProposals(from: log, canvasSize: canvasSize)
        #expect(proposals.count == 1)
        // snap-zoom-on-click pattern: identity → zoom → zoom → identity = 4 keyframes
        #expect(proposals[0].keyframes.count == 4)
    }
}

// MARK: - KeystrokeOverlayGenerator

@Suite("KeystrokeOverlayGenerator")
struct KeystrokeOverlayGeneratorTests {
    @Test("Repeated same-key presses at distinct times are preserved")
    func repeatedKeyPressesArePreserved() throws {
        let events = [
            ScreencastEvent(
                time: CMTime(seconds: 1, preferredTimescale: 600),
                kind: .key,
                keyCode: 0x00,
                modifierFlagsRaw: 0,
                keyPhase: .down),
            ScreencastEvent(
                time: CMTime(seconds: 1.4, preferredTimescale: 600),
                kind: .key,
                keyCode: 0x00,
                modifierFlagsRaw: 0,
                keyPhase: .down),
        ]
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: events)
        let clip = try #require(KeystrokeOverlayGenerator.generate(from: log))

        #expect(clip.events.map(\.displayText) == ["A", "A"])
        #expect(clip.events.map { $0.time.seconds } == [1.0, 1.4])
    }

    @Test("Key-up events are dropped when the log carries key phase")
    func keyUpEventsAreDropped() throws {
        let events = [
            ScreencastEvent(
                time: CMTime(seconds: 2, preferredTimescale: 600),
                kind: .key,
                keyCode: 0x0B,
                modifierFlagsRaw: 0,
                keyPhase: .down),
            ScreencastEvent(
                time: CMTime(seconds: 2.1, preferredTimescale: 600),
                kind: .key,
                keyCode: 0x0B,
                modifierFlagsRaw: 0,
                keyPhase: .up),
        ]
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: events)
        let clip = try #require(KeystrokeOverlayGenerator.generate(from: log))

        #expect(clip.events.map(\.displayText) == ["B"])
    }

    @Test("Legacy duplicate key events at the same timestamp are de-duplicated")
    func legacyDuplicateEventsAreDeduplicated() throws {
        let timestamp = CMTime(seconds: 3, preferredTimescale: 600)
        let events = [
            ScreencastEvent(time: timestamp, kind: .key, keyCode: 0x08, modifierFlagsRaw: 0),
            ScreencastEvent(time: timestamp, kind: .key, keyCode: 0x08, modifierFlagsRaw: 0),
        ]
        let log = ScreencastEventLog(schemaVersion: 1, sessionID: UUID(), events: events)
        let clip = try #require(KeystrokeOverlayGenerator.generate(from: log))

        #expect(clip.events.map(\.displayText) == ["C"])
    }
}
