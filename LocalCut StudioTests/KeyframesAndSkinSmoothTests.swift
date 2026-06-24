import Testing
import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import LocalCutCore
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

@Test("Skin-smooth blur radius scales from a 1080p source-height reference")
func skinSmoothBlurRadiusScalesWithSourceHeight() {
    let full = EffectCompositor.skinSmoothBlurRadius(strength: 1, imageHeight: 1080)
    let fourK = EffectCompositor.skinSmoothBlurRadius(strength: 1, imageHeight: 2160)
    let half = EffectCompositor.skinSmoothBlurRadius(strength: 1, imageHeight: 540)
    let halfStrength = EffectCompositor.skinSmoothBlurRadius(strength: 0.5, imageHeight: 2160)

    #expect(abs(full - 10) < 0.001)
    #expect(abs(fourK - 20) < 0.001)
    #expect(abs(half - 5) < 0.001)
    #expect(abs(halfStrength - 10) < 0.001)
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

// MARK: - Skin-smooth render path (D1: MSL kernel migration)

/// Exercises the *compiled* Metal kernels end-to-end, not just the model. A
/// missing `default.metallib` or a renamed kernel function makes `skinMaskKernel`
/// nil → `applySkinSmooth` returns nil here, so this fails loudly instead of the
/// effect silently no-op-ing in preview/export while the model tests stay green.
@Test("Skin-smooth render path: MSL kernels load and change a skin-tone fixture")
func skinSmoothRenderPathAltersPixels() throws {
    // 64×64 checkerboard of two skin-tones: high-frequency detail inside a region
    // the chroma mask classifies as skin, so the masked blur has something to smooth.
    let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
    let checker = CIFilter.checkerboardGenerator()
    checker.color0 = CIColor(red: 0.85, green: 0.65, blue: 0.55)
    checker.color1 = CIColor(red: 0.55, green: 0.38, blue: 0.32)
    checker.width = 4
    checker.center = CGPoint(x: 0, y: 0)
    let fixture = try #require(checker.outputImage).cropped(to: extent)

    var params = SkinSmoothEffect()
    params.strength.defaultValue = 1.0  // full strength so the change is unmistakable

    let compositor = EffectCompositor()
    let smoothed = try #require(
        compositor.applySkinSmooth(fixture, params: params, at: .zero),
        "Skin-smooth Metal kernels failed to load or run")

    // Render both to bitmaps (shared software renderer for deterministic headless
    // CI) and assert the blend kernel actually changed pixels.
    let space = CGColorSpaceCreateDeviceRGB()
    func bitmap(_ image: CIImage) -> [UInt8] {
        let rowBytes = 64 * 4
        var buffer = [UInt8](repeating: 0, count: rowBytes * 64)
        buffer.withUnsafeMutableBytes { raw in
            skinFixtureSoftwareContext.render(image, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                                              bounds: extent, format: .RGBA8, colorSpace: space)
        }
        return buffer
    }
    #expect(bitmap(fixture) != bitmap(smoothed))
}

// MARK: - Skin-smooth snapshot at three strengths (T3.1)

// Synthetic fixture geometry: three equal vertical bands, each tall enough that
// the source-height-scaled blur radius (10px @ 1080p → 5px @ 540p, full strength)
// is several pixels — large enough to visibly soften the fine checkerboard.
private let skinFixtureWidth = 360
private let skinFixtureHeight = 540
private let skinFixtureBand = skinFixtureWidth / 3   // 120
private let skinFixtureExtent = CGRect(x: 0, y: 0,
                                       width: CGFloat(skinFixtureWidth),
                                       height: CGFloat(skinFixtureHeight))

/// Builds the skin + foliage + graphics fixture. The bands are chosen so the
/// chroma / luminance mask classifies only the left band as skin:
/// - **skin** — two warm skin tones (both inside the YCbCr skin box),
/// - **foliage** — greens (cr well below the skin range → mask ≈ 0),
/// - **graphics** — cyan↔blue *soft* stripes standing in for overlaid title /
///   caption graphics.
///
/// The graphics band is deliberately **not** black/white "text". The chroma-only
/// mask classifies neutral mid-grays as skin (a documented phase-32a trade-off —
/// `(0.5,0.5,0.5)` lands inside the chroma box), so a black/white band would only
/// be excluded at the exact y≈0 / y≈1 endpoints while its *antialiased gray
/// edges* — the realistic failure mode for overlaid text — would be smoothed.
/// Cyan `(0,1,1)` and blue `(0,0,1)` differ only in the green channel, and across
/// that whole line `cr ≤ 0.42`, comfortably below the skin range's `crMin` of
/// 0.45 — so every pixel, including the soft (antialiased) transition pixels the
/// stripe generator produces, has `crDist == 0` and is excluded from the mask.
/// That makes the "non-skin untouched" assertion robust to antialiasing rather
/// than reliant on the luminance gate at the extremes.
private func makeSkinFoliageGraphicsFixture() throws -> CIImage {
    func checkerBand(_ c0: CIColor, _ c1: CIColor, x: Int) -> CIImage? {
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = c0
        checker.color1 = c1
        checker.width = 10                       // pixel-aligned cells → sharp edges
        checker.center = CGPoint(x: 0, y: 0)
        return checker.outputImage?.cropped(
            to: CGRect(x: CGFloat(x), y: 0,
                       width: CGFloat(skinFixtureBand),
                       height: CGFloat(skinFixtureHeight)))
    }
    let skin = try #require(checkerBand(CIColor(red: 0.85, green: 0.65, blue: 0.55),
                                        CIColor(red: 0.55, green: 0.38, blue: 0.32), x: 0))
    let foliage = try #require(checkerBand(CIColor(red: 0.20, green: 0.55, blue: 0.20),
                                           CIColor(red: 0.12, green: 0.38, blue: 0.14), x: skinFixtureBand))
    // Soft (sharpness < 1) stripes → genuine antialiased cyan↔blue transition
    // pixels. The two colours differ only in green, so every blend keeps
    // cr ≤ 0.42 (< crMin 0.45) → crDist 0 → the whole band stays non-skin.
    let stripes = CIFilter.stripesGenerator()
    stripes.color0 = CIColor(red: 0.0, green: 1.0, blue: 1.0)
    stripes.color1 = CIColor(red: 0.0, green: 0.0, blue: 1.0)
    stripes.width = 8
    stripes.sharpness = 0.6
    stripes.center = CGPoint(x: 0, y: 0)
    let graphics = try #require(stripes.outputImage?.cropped(
        to: CGRect(x: CGFloat(skinFixtureBand * 2), y: 0,
                   width: CGFloat(skinFixtureBand),
                   height: CGFloat(skinFixtureHeight))))
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: skinFixtureExtent)
    return skin.composited(over: foliage.composited(over: graphics.composited(over: black)))
}

/// Shared software-renderer context: `CIContext` creation is resource-intensive,
/// and the snapshot renders the fixture several times per run, so one reused
/// instance avoids repeated setup cost. Software renderer keeps the snapshot
/// deterministic on headless CI (no GPU-dependent rounding).
private let skinFixtureSoftwareContext = CIContext(options: [.useSoftwareRenderer: true])

/// Software-renders `image` over the fixture extent to a tightly-packed RGBA8
/// buffer, the same deterministic choice the render-path and caption-preset
/// snapshot tests make.
private func renderSkinFixtureRGBA8(_ image: CIImage) -> [UInt8] {
    let space = CGColorSpaceCreateDeviceRGB()
    let rowBytes = skinFixtureWidth * 4
    var buffer = [UInt8](repeating: 0, count: rowBytes * skinFixtureHeight)
    buffer.withUnsafeMutableBytes { raw in
        skinFixtureSoftwareContext.render(image, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                                          bounds: skinFixtureExtent, format: .RGBA8, colorSpace: space)
    }
    return buffer
}

/// Total-variation of luminance over an interior x-range: the sum of horizontal
/// and vertical neighbour differences. Higher = more high-frequency detail, so
/// a Gaussian smoothing pass drives it down. The 24px y-margin and the caller's
/// inset x-ranges keep the measurement clear of band seams and the few pixels of
/// cross-band Gaussian bleed.
private func skinFixtureDetailEnergy(_ buffer: [UInt8], xRange: Range<Int>) -> Double {
    let w = skinFixtureWidth
    let bytesPerPixel = 4
    func lum(at i: Int) -> Double {
        return (Double(buffer[i]) + Double(buffer[i + 1]) + Double(buffer[i + 2])) / 3.0
    }
    let margin = 24
    var energy = 0.0
    for y in margin..<(skinFixtureHeight - margin) {
        for x in xRange {
            let i = (y * w + x) * bytesPerPixel
            let current = lum(at: i)
            energy += abs(current - lum(at: i + bytesPerPixel))
            energy += abs(current - lum(at: i + w * bytesPerPixel))
        }
    }
    return energy
}

/// T3.1 snapshot: render the skin + foliage + graphics fixture through the real
/// skin-smooth kernels at three strengths and assert the *golden behaviour* the
/// phase promises — the skin band loses high-frequency detail monotonically with
/// strength, while the foliage and graphics bands stay within tolerance of the
/// un-smoothed baseline ("non-skin regions left untouched"). This is the
/// "golden-less" snapshot form the caption-preset test established: it avoids
/// committed PNGs (which would need a GPU-determinism + colour-sync matrix) while
/// still pinning the behaviour a pixel golden would catch.
@Test("Skin-smooth snapshot: skin band smooths with strength, foliage + graphics untouched (T3.1)")
func skinSmoothSnapshotThreeStrengths() throws {
    let fixture = try makeSkinFoliageGraphicsFixture()
    let compositor = EffectCompositor()

    // Strength 0 is a documented no-op: the effect returns nil, so the baseline
    // "render" is the fixture itself.
    var off = SkinSmoothEffect()
    off.strength.defaultValue = 0
    #expect(compositor.applySkinSmooth(fixture, params: off, at: .zero) == nil,
            "strength 0 must be a no-op (identity)")

    func render(strength: Float) throws -> [UInt8] {
        guard strength > 0 else { return renderSkinFixtureRGBA8(fixture) }
        var params = SkinSmoothEffect()
        params.strength.defaultValue = strength
        let smoothed = try #require(
            compositor.applySkinSmooth(fixture, params: params, at: .zero),
            "skin-smooth kernels failed to load or run")
        return renderSkinFixtureRGBA8(smoothed)
    }

    let r0 = try render(strength: 0)
    let r05 = try render(strength: 0.5)
    let r1 = try render(strength: 1.0)

    // Interior x-ranges per band (24px inset clears the seams + Gaussian bleed).
    let skinX = 24..<96
    let foliageX = (skinFixtureBand + 24)..<(skinFixtureBand * 2 - 24)
    let graphicsX = (skinFixtureBand * 2 + 24)..<(skinFixtureWidth - 24)

    // Skin band: detail decreases monotonically with strength, and full strength
    // removes a clear share of the high-frequency energy.
    let skin0 = skinFixtureDetailEnergy(r0, xRange: skinX)
    let skin05 = skinFixtureDetailEnergy(r05, xRange: skinX)
    let skin1 = skinFixtureDetailEnergy(r1, xRange: skinX)
    #expect(skin0 > skin05, "half strength should smooth the skin band below baseline")
    #expect(skin05 > skin1, "full strength should smooth the skin band more than half")
    #expect(skin1 < skin0 * 0.8, "full strength should remove a clear share of skin detail")

    // Foliage + graphics bands sit outside the skin mask, so they must stay
    // within a tight tolerance of the baseline at every strength ("untouched").
    let bands: [(name: String, base: Double, xRange: Range<Int>)] = [
        ("foliage", skinFixtureDetailEnergy(r0, xRange: foliageX), foliageX),
        ("graphics", skinFixtureDetailEnergy(r0, xRange: graphicsX), graphicsX),
    ]
    // Each non-skin band must carry detail to compare against; a zero baseline
    // would make the relative drift undefined (the patterns guarantee it, but
    // assert it so a future fixture change fails loudly rather than dividing by 0).
    for band in bands {
        #expect(band.base > 0, "\(band.name) band has no baseline detail to compare")
        for (label, buffer) in [("0.5", r05), ("1.0", r1)] {
            let energy = skinFixtureDetailEnergy(buffer, xRange: band.xRange)
            let drift = band.base > 0 ? abs(energy - band.base) / band.base : abs(energy - band.base)
            #expect(drift < 0.02,
                    "\(band.name) band drifted \(drift) at strength \(label) — should be untouched")
        }
    }
}
