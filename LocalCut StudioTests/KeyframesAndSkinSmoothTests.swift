import Testing
import AVFoundation
import CoreGraphics
@testable import LocalCut_Studio

// MARK: - Keyframe Tests

@Test("Keyframed with empty keyframes returns default value")
func keyframedEmptyReturnsDefault() {
    let keyframed = Keyframed<Float>(defaultValue: 0.5)
    #expect(keyframed.value(at: .zero) == 0.5)
    #expect(keyframed.value(at: CMTime(seconds: 10, preferredTimescale: 600)) == 0.5)
    #expect(!keyframed.isAnimated)
}

@Test("Keyframed with single keyframe returns that value")
func keyframedSingleKeyframe() {
    let keyframe = Keyframe<Float>(time: CMTime(seconds: 5, preferredTimescale: 600), value: 0.8)
    let keyframed = Keyframed<Float>(keyframes: [keyframe], defaultValue: 0.0)
    
    #expect(keyframed.isAnimated)
    #expect(keyframed.value(at: .zero) == 0.8) // Before first keyframe
    #expect(keyframed.value(at: CMTime(seconds: 5, preferredTimescale: 600)) == 0.8) // At keyframe
    #expect(keyframed.value(at: CMTime(seconds: 10, preferredTimescale: 600)) == 0.8) // After last keyframe
}

@Test("Keyframed interpolates between two keyframes")
func keyframedInterpolation() {
    let k1 = Keyframe<Float>(time: CMTime(seconds: 0, preferredTimescale: 600), value: 0.0)
    let k2 = Keyframe<Float>(time: CMTime(seconds: 10, preferredTimescale: 600), value: 1.0)
    let keyframed = Keyframed<Float>(keyframes: [k1, k2], defaultValue: 0.5)
    
    #expect(keyframed.value(at: CMTime(seconds: 0, preferredTimescale: 600)) == 0.0)
    #expect(keyframed.value(at: CMTime(seconds: 5, preferredTimescale: 600)) == 0.5)
    #expect(keyframed.value(at: CMTime(seconds: 10, preferredTimescale: 600)) == 1.0)
}

@Test("Keyframed clamps to first value before first keyframe")
func keyframedClampBeforeFirst() {
    let k1 = Keyframe<Float>(time: CMTime(seconds: 5, preferredTimescale: 600), value: 0.2)
    let k2 = Keyframe<Float>(time: CMTime(seconds: 10, preferredTimescale: 600), value: 0.8)
    let keyframed = Keyframed<Float>(keyframes: [k1, k2], defaultValue: 0.0)
    
    #expect(keyframed.value(at: .zero) == 0.2)
    #expect(keyframed.value(at: CMTime(seconds: 3, preferredTimescale: 600)) == 0.2)
}

@Test("Keyframed clamps to last value after last keyframe")
func keyframedClampAfterLast() {
    let k1 = Keyframe<Float>(time: CMTime(seconds: 0, preferredTimescale: 600), value: 0.2)
    let k2 = Keyframe<Float>(time: CMTime(seconds: 5, preferredTimescale: 600), value: 0.8)
    let keyframed = Keyframed<Float>(keyframes: [k1, k2], defaultValue: 0.0)
    
    #expect(keyframed.value(at: CMTime(seconds: 10, preferredTimescale: 600)) == 0.8)
    #expect(keyframed.value(at: CMTime(seconds: 100, preferredTimescale: 600)) == 0.8)
}

@Test("Keyframed addKeyframe maintains sorted order")
func keyframedAddKeyframeSorted() {
    var keyframed = Keyframed<Float>(defaultValue: 0.0)
    
    keyframed.addKeyframe(at: CMTime(seconds: 10, preferredTimescale: 600), value: 0.8)
    keyframed.addKeyframe(at: CMTime(seconds: 0, preferredTimescale: 600), value: 0.2)
    keyframed.addKeyframe(at: CMTime(seconds: 5, preferredTimescale: 600), value: 0.5)
    
    #expect(keyframed.keyframes.count == 3)
    #expect(keyframed.keyframes[0].time == CMTime(seconds: 0, preferredTimescale: 600))
    #expect(keyframed.keyframes[1].time == CMTime(seconds: 5, preferredTimescale: 600))
    #expect(keyframed.keyframes[2].time == CMTime(seconds: 10, preferredTimescale: 600))
}

@Test("Keyframed addKeyframe replaces existing at same time")
func keyframedAddKeyframeReplace() {
    var keyframed = Keyframed<Float>(defaultValue: 0.0)
    
    keyframed.addKeyframe(at: CMTime(seconds: 5, preferredTimescale: 600), value: 0.5)
    keyframed.addKeyframe(at: CMTime(seconds: 5, preferredTimescale: 600), value: 0.8)
    
    #expect(keyframed.keyframes.count == 1)
    #expect(keyframed.keyframes[0].value == 0.8)
}

@Test("Keyframed removeKeyframe works")
func keyframedRemoveKeyframe() {
    let k1 = Keyframe<Float>(time: CMTime(seconds: 0, preferredTimescale: 600), value: 0.0)
    let k2 = Keyframe<Float>(time: CMTime(seconds: 10, preferredTimescale: 600), value: 1.0)
    var keyframed = Keyframed<Float>(keyframes: [k1, k2], defaultValue: 0.5)
    
    keyframed.removeKeyframe(id: k1.id)
    
    #expect(keyframed.keyframes.count == 1)
    #expect(keyframed.keyframes[0].id == k2.id)
}

@Test("Keyframed updateKeyframe works")
func keyframedUpdateKeyframe() {
    let k1 = Keyframe<Float>(time: CMTime(seconds: 0, preferredTimescale: 600), value: 0.0)
    var keyframed = Keyframed<Float>(keyframes: [k1], defaultValue: 0.5)
    
    keyframed.updateKeyframe(id: k1.id, value: 0.8)
    
    #expect(keyframed.keyframes[0].value == 0.8)
}

@Test("Keyframed updateKeyframe maintains sorted order after time change")
func keyframedUpdateKeyframeTime() {
    let k1 = Keyframe<Float>(time: CMTime(seconds: 0, preferredTimescale: 600), value: 0.0)
    let k2 = Keyframe<Float>(time: CMTime(seconds: 10, preferredTimescale: 600), value: 1.0)
    var keyframed = Keyframed<Float>(keyframes: [k1, k2], defaultValue: 0.5)
    
    keyframed.updateKeyframe(id: k1.id, time: CMTime(seconds: 15, preferredTimescale: 600))
    
    #expect(keyframed.keyframes[0].id == k2.id)
    #expect(keyframed.keyframes[1].id == k1.id)
}

// MARK: - SkinSmoothEffect Tests

@Test("SkinSmoothEffect neutral defaults")
func skinSmoothNeutralDefaults() {
    let effect = SkinSmoothEffect()
    #expect(effect.strength.defaultValue == 0)
    #expect(effect.maskWarmthBias == 0)
    #expect(effect.maskLuminanceGate == 0.1)
    #expect(!effect.bypass)
}

@Test("SkinSmoothEffect clamp enforces ranges")
func skinSmoothClamp() {
    var effect = SkinSmoothEffect()
    effect.maskWarmthBias = 2.0
    effect.maskLuminanceGate = -0.5
    effect.strength.defaultValue = 1.5
    
    effect.clamp()
    
    #expect(effect.maskWarmthBias == 1.0)
    #expect(effect.maskLuminanceGate == 0.0)
    #expect(effect.strength.defaultValue == 1.0)
}

@Test("SkinSmoothEffect clamp preserves in-range values")
func skinSmoothClampPreservesInRange() {
    var effect = SkinSmoothEffect()
    effect.maskWarmthBias = 0.5
    effect.maskLuminanceGate = 0.7
    effect.strength.defaultValue = 0.3
    
    effect.clamp()
    
    #expect(effect.maskWarmthBias == 0.5)
    #expect(effect.maskLuminanceGate == 0.7)
    #expect(effect.strength.defaultValue == 0.3)
}

@Test("Effect.skinSmooth stores effect")
func effectSkinSmoothStores() {
    let effect = Effect.skinSmooth(SkinSmoothEffect())
    guard case .skinSmooth(let smooth) = effect else {
        Issue.record("Expected .skinSmooth effect")
        return
    }
    #expect(smooth.strength.defaultValue == 0)
}

// MARK: - Codable Tests

@Test("Keyframed Codable round-trip preserves data")
func keyframedCodableRoundTrip() throws {
    let k1 = Keyframe<Float>(time: CMTime(seconds: 0, preferredTimescale: 600), value: 0.0)
    let k2 = Keyframe<Float>(time: CMTime(seconds: 10, preferredTimescale: 600), value: 1.0)
    let keyframed = Keyframed<Float>(keyframes: [k1, k2], defaultValue: 0.5)
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(keyframed)
    
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(Keyframed<Float>.self, from: data)
    
    #expect(decoded.defaultValue == keyframed.defaultValue)
    #expect(decoded.keyframes.count == keyframed.keyframes.count)
    #expect(decoded.keyframes[0].value == keyframed.keyframes[0].value)
    #expect(decoded.keyframes[1].value == keyframed.keyframes[1].value)
}

@Test("SkinSmoothEffect Codable round-trip preserves data")
func skinSmoothCodableRoundTrip() throws {
    var effect = SkinSmoothEffect()
    effect.strength = Keyframed<Float>(keyframes: [
        Keyframe<Float>(time: CMTime(seconds: 0, preferredTimescale: 600), value: 0.0),
        Keyframe<Float>(time: CMTime(seconds: 5, preferredTimescale: 600), value: 0.8)
    ], defaultValue: 0.0)
    effect.maskWarmthBias = 0.3
    effect.maskLuminanceGate = 0.6
    effect.bypass = true
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(effect)
    
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(SkinSmoothEffect.self, from: data)
    
    #expect(decoded.strength.defaultValue == effect.strength.defaultValue)
    #expect(decoded.strength.keyframes.count == effect.strength.keyframes.count)
    #expect(decoded.maskWarmthBias == effect.maskWarmthBias)
    #expect(decoded.maskLuminanceGate == effect.maskLuminanceGate)
    #expect(decoded.bypass == effect.bypass)
}
