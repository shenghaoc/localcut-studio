import Testing
import AVFoundation
import CoreGraphics
import CoreImage
@testable import LocalCut_Studio

// MARK: - T1.2 Unit tests

@Test("ColourGrade neutral defaults are identity")
func neutralDefaults() {
    let grade = ColourGrade()
    #expect(grade.exposure == 0)
    #expect(grade.contrast == 1)
    #expect(grade.saturation == 1)
    #expect(grade.temperatureOffset == 0)
    #expect(grade.tintOffset == 0)
}

@Test("ColourGrade.clamp() enforces documented ranges")
func clamping() {
    var grade = ColourGrade()
    grade.exposure = 5
    grade.contrast = 3
    grade.saturation = -1
    grade.temperatureOffset = 5000
    grade.tintOffset = 200
    grade.clamp()
    #expect(grade.exposure == 2)
    #expect(grade.contrast == 1.5)
    #expect(grade.saturation == 0)
    #expect(grade.temperatureOffset == 4000)
    #expect(grade.tintOffset == 150)
}

@Test("ColourGrade.clamp() preserves in-range values")
func noClampingWhenInRange() {
    var grade = ColourGrade()
    grade.exposure = -1
    grade.contrast = 0.8
    grade.saturation = 1.5
    grade.temperatureOffset = 1000
    grade.tintOffset = -50
    grade.clamp()
    #expect(grade.exposure == -1)
    #expect(grade.contrast == 0.8)
    #expect(grade.saturation == 1.5)
    #expect(grade.temperatureOffset == 1000)
    #expect(grade.tintOffset == -50)
}

@Test("Clip has empty effects by default")
func clipDefaultEffects() {
    let clip = Clip(mediaID: UUID(), sourceStart: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600), timelineStart: .zero)
    #expect(clip.effects.isEmpty)
}

@Test("Effect.colourGrade identity is neutral")
func colourGradeEffectIdentity() {
    let effect = Effect.colourGrade(.neutral)
    guard case .colourGrade(let grade) = effect else {
        Issue.record("Expected .colourGrade effect")
        return
    }
    #expect(grade.exposure == 0)
    #expect(grade.contrast == 1)
}

@Test("EffectCompositor.applyEffectChain: empty chain is byte-for-byte identity (T1.2 pass-through R5.1)")
@MainActor
func emptyEffectChainIsIdentity() {
    let compositor = EffectCompositor()
    let source = CIImage(color: CIColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    let result = compositor.applyEffectChain(source, effects: [], cacheKey: nil)
    // The early-return contract: empty chain returns the *same* CIImage object,
    // not a new one. CIImage is a value-like reference; comparing extent + a
    // sampled pixel guarantees identity even if the CIImage wrapper is rewrapped.
    #expect(result.extent == source.extent)
    #expect(samplePixelEquals(result, source, at: CGPoint(x: 8, y: 8)))
}

@Test("EffectCompositor.applyEffectChain: neutral colour grade is also identity (R5.1)")
@MainActor
func neutralColourGradeIsIdentity() {
    let compositor = EffectCompositor()
    let source = CIImage(color: CIColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    let result = compositor.applyEffectChain(
        source, effects: [.colourGrade(.neutral)], cacheKey: nil)
    #expect(result.extent == source.extent)
    #expect(samplePixelEquals(result, source, at: CGPoint(x: 8, y: 8), tolerance: 0.005))
}

/// Renders `a` and `b` to single-pixel CGImages at `point` and compares the
/// RGBA bytes. Used by the colour-grading pass-through tests; lives near the
/// top of the file so multiple tests can share it.
@MainActor
private func samplePixelEquals(_ a: CIImage, _ b: CIImage, at point: CGPoint,
                               tolerance: Double = 0) -> Bool {
    let context = CIContext(options: nil)
    let one = CGRect(x: point.x, y: point.y, width: 1, height: 1)
    guard let ca = context.createCGImage(a, from: one),
          let cb = context.createCGImage(b, from: one),
          let pa = ca.dataProvider?.data, let pb = cb.dataProvider?.data,
          let ba = CFDataGetBytePtr(pa), let bb = CFDataGetBytePtr(pb) else { return false }
    let n = min(CFDataGetLength(pa), CFDataGetLength(pb))
    for i in 0..<n {
        let diff = abs(Double(ba[i]) - Double(bb[i])) / 255.0
        if diff > tolerance { return false }
    }
    return true
}

@Test("Effect.lut stores bookmark data")
func lutEffectStoresData() {
    let data = Data([0x01, 0x02, 0x03])
    let effect = Effect.lut(bookmark: data)
    guard case .lut(bookmark: let stored) = effect else {
        Issue.record("Expected .lut effect")
        return
    }
    #expect(stored == data)
}
