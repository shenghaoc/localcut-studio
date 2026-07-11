import Testing
import Foundation
import LocalCutDomain

// MARK: - Tier ordering (R1.1)

@Test("CapabilityTier: ordering is baseline < accelerated < pro")
func capabilityTierOrdering() {
    #expect(CapabilityTier.baseline < .accelerated)
    #expect(CapabilityTier.accelerated < .pro)
    #expect(CapabilityTier.baseline < .pro)
    #expect(!(CapabilityTier.pro < .baseline))
}

@Test("CapabilityTier: Codable round-trips through JSON")
func capabilityTierCodable() throws {
    let encoded = try JSONEncoder().encode([CapabilityTier.baseline, .accelerated, .pro])
    let decoded = try JSONDecoder().decode([CapabilityTier].self, from: encoded)
    #expect(decoded == [.baseline, .accelerated, .pro])
}

// MARK: - Frame interpolation gating (R3.4)

@Test("Frame interpolation: Intel → baseline regardless of OS version")
func frameInterpolationIntel() {
    let intel = Capabilities(
        chip: .intel,
        unifiedMemoryBytes: 32 * 1024 * 1024 * 1024,
        videoEncoderCount: 0,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = intel.tier(for: .frameInterpolation)
    #expect(verdict.tier == .baseline)
    #expect(verdict.reason.lowercased().contains("intel"))
}

@Test("Frame interpolation: macOS 15.3 on Apple Silicon → baseline (OS gate)")
func frameInterpolationOldOS() {
    let oldOS = Capabilities(
        chip: .appleSilicon(generation: 3),
        unifiedMemoryBytes: 32 * 1024 * 1024 * 1024,
        videoEncoderCount: 2,
        osVersion: Capabilities.OSVersion(major: 15, minor: 3))
    let verdict = oldOS.tier(for: .frameInterpolation)
    #expect(verdict.tier == .baseline)
    #expect(verdict.reason.contains("15.4"))
}

@Test("Frame interpolation: macOS 15.4 on M1 → accelerated")
func frameInterpolationM1() {
    let m1 = Capabilities(
        chip: .appleSilicon(generation: 1),
        unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
        videoEncoderCount: 1,
        osVersion: Capabilities.OSVersion(major: 15, minor: 4))
    let verdict = m1.tier(for: .frameInterpolation)
    #expect(verdict.tier == .accelerated)
    #expect(verdict.reason.contains("M1"))
}

@Test("Frame interpolation: M2 with 8 GiB → accelerated (chip-class ceiling)")
func frameInterpolationM2LowMem() {
    let m2 = Capabilities(
        chip: .appleSilicon(generation: 2),
        unifiedMemoryBytes: 8 * 1024 * 1024 * 1024,
        videoEncoderCount: 1,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = m2.tier(for: .frameInterpolation)
    #expect(verdict.tier == .accelerated)
    #expect(verdict.reason.contains("M2"))
}

@Test("Frame interpolation: M2 with 64 GiB → accelerated (pro reserved for M3+)")
func frameInterpolationM2HighMem() {
    let m2 = Capabilities(
        chip: .appleSilicon(generation: 2),
        unifiedMemoryBytes: 64 * 1024 * 1024 * 1024,
        videoEncoderCount: 2,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = m2.tier(for: .frameInterpolation)
    #expect(verdict.tier == .accelerated)
    #expect(verdict.reason.contains("M2"))
}

@Test("Frame interpolation: M3 with 16 GiB → accelerated (memory below pro threshold)")
func frameInterpolationM3BaseMem() {
    let m3 = Capabilities(
        chip: .appleSilicon(generation: 3),
        unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
        videoEncoderCount: 1,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = m3.tier(for: .frameInterpolation)
    #expect(verdict.tier == .accelerated)
    #expect(verdict.reason.contains("M3"))
}

@Test("Frame interpolation: M3 with 32 GiB → pro (Pro/Max/Ultra-class)")
func frameInterpolationM3Pro() {
    let m3 = Capabilities(
        chip: .appleSilicon(generation: 3),
        unifiedMemoryBytes: 32 * 1024 * 1024 * 1024,
        videoEncoderCount: 2,
        osVersion: Capabilities.OSVersion(major: 26, minor: 1))
    let verdict = m3.tier(for: .frameInterpolation)
    #expect(verdict.tier == .pro)
    #expect(verdict.reason.contains("M3"))
}

@Test("Frame interpolation: unknown AS generation → baseline (errs low)")
func frameInterpolationUnknownAS() {
    let unknown = Capabilities(
        chip: .appleSilicon(generation: 0),
        unifiedMemoryBytes: 64 * 1024 * 1024 * 1024,
        videoEncoderCount: 4,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = unknown.tier(for: .frameInterpolation)
    #expect(verdict.tier == .baseline)
}

// MARK: - Baseline never reaches accelerated (R3.6)

@Test("Baseline hardware never reaches accelerated for any feature")
func baselineNeverReachesAccelerated() {
    let intel = Capabilities(
        chip: .intel,
        unifiedMemoryBytes: 32 * 1024 * 1024 * 1024,
        videoEncoderCount: 0,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    for feature in [
        CapabilityFeature.frameInterpolation,
        .simultaneousCaptureStreams(count: 1),
        .metalEffectChain,
    ] {
        let verdict = intel.tier(for: feature)
        #expect(verdict.tier == .baseline,
                "Intel host returned \(verdict.tier) for \(feature)")
    }
}

// MARK: - Simultaneous capture streams (R3.5)

@Test("Capture streams: requested count > encoder count → baseline")
func captureStreamsExceedEncoders() {
    let c = Capabilities(
        chip: .appleSilicon(generation: 3),
        unifiedMemoryBytes: 32 * 1024 * 1024 * 1024,
        videoEncoderCount: 1,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = c.tier(for: .simultaneousCaptureStreams(count: 3))
    #expect(verdict.tier == .baseline)
    #expect(verdict.reason.lowercased().contains("encoder"))
}

@Test("Capture streams: 1 stream on 1 encoder Apple Silicon → accelerated")
func captureStreamsSingle() {
    let c = Capabilities(
        chip: .appleSilicon(generation: 2),
        unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
        videoEncoderCount: 1,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = c.tier(for: .simultaneousCaptureStreams(count: 1))
    #expect(verdict.tier == .accelerated)
}

@Test("Capture streams: 3 streams + 3 encoders, ≥16 GiB → pro")
func captureStreamsProMulti() {
    let c = Capabilities(
        chip: .appleSilicon(generation: 3),
        unifiedMemoryBytes: 32 * 1024 * 1024 * 1024,
        videoEncoderCount: 3,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = c.tier(for: .simultaneousCaptureStreams(count: 3))
    #expect(verdict.tier == .pro)
}

// MARK: - Metal effect chain

@Test("Metal effect chain: Intel → baseline (no unified memory)")
func metalEffectChainIntel() {
    let intel = Capabilities(
        chip: .intel,
        unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
        videoEncoderCount: 0,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = intel.tier(for: .metalEffectChain)
    #expect(verdict.tier == .baseline)
}

@Test("Metal effect chain: unknown AS generation → baseline (errs low)")
func metalEffectChainUnknownAS() {
    let unknown = Capabilities(
        chip: .appleSilicon(generation: 0),
        unifiedMemoryBytes: 64 * 1024 * 1024 * 1024,
        videoEncoderCount: 4,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = unknown.tier(for: .metalEffectChain)
    #expect(verdict.tier == .baseline)
}

@Test("Metal effect chain: Apple Silicon M2 with 8 GiB → accelerated")
func metalEffectChainLowMemAS() {
    let c = Capabilities(
        chip: .appleSilicon(generation: 2),
        unifiedMemoryBytes: 8 * 1024 * 1024 * 1024,
        videoEncoderCount: 1,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = c.tier(for: .metalEffectChain)
    #expect(verdict.tier == .accelerated)
    #expect(verdict.reason.contains("M2"))
}

@Test("Metal effect chain: M-series with ≥16 GiB → pro")
func metalEffectChainPro() {
    let m2 = Capabilities(
        chip: .appleSilicon(generation: 2),
        unifiedMemoryBytes: 32 * 1024 * 1024 * 1024,
        videoEncoderCount: 1,
        osVersion: Capabilities.OSVersion(major: 26, minor: 0))
    let verdict = m2.tier(for: .metalEffectChain)
    #expect(verdict.tier == .pro)
}

// MARK: - Board-string → generation table

@Test("Apple Silicon generation: maps known Mac family prefixes")
func appleSiliconGenerationFromBoard() {
    #expect(Capabilities.appleSiliconGeneration(forBoard: "Mac16,1") == 4)
    #expect(Capabilities.appleSiliconGeneration(forBoard: "Mac15,7") == 3)
    #expect(Capabilities.appleSiliconGeneration(forBoard: "Mac14,15") == 2)
    #expect(Capabilities.appleSiliconGeneration(forBoard: "Mac13,1") == 1)
    #expect(Capabilities.appleSiliconGeneration(forBoard: "MacBookAir10,1") == 1)
    #expect(Capabilities.appleSiliconGeneration(forBoard: "Mac99,99") == 0)
}

// MARK: - ChipFamily conveniences

@Test("ChipFamily: isAppleSilicon and generation accessors")
func chipFamilyAccessors() {
    let intel = Capabilities.ChipFamily.intel
    #expect(intel.isAppleSilicon == false)
    #expect(intel.generation == nil)

    let m3 = Capabilities.ChipFamily.appleSilicon(generation: 3)
    #expect(m3.isAppleSilicon == true)
    #expect(m3.generation == 3)
}

// MARK: - Phase 45: Program Mode capability

@Test("Program Mode: Intel Mac resolves to baseline")
func programModeIntelBaseline() {
    let caps = Capabilities(
        chip: .intel,
        unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
        videoEncoderCount: 0,
        osVersion: .init(major: 26, minor: 0))
    let verdict = caps.tier(for: .programMode)
    #expect(verdict.tier == .baseline)
    #expect(verdict.reason.contains("Intel"))
}

@Test("Program Mode: no hardware encoders resolves to baseline")
func programModeNoEncodersBaseline() {
    let caps = Capabilities(
        chip: .appleSilicon(generation: 2),
        unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
        videoEncoderCount: 0,
        osVersion: .init(major: 26, minor: 0))
    let verdict = caps.tier(for: .programMode)
    #expect(verdict.tier == .baseline)
    #expect(verdict.reason.contains("No hardware"))
}

@Test("Program Mode: unknown Apple Silicon generation resolves to baseline")
func programModeUnknownGenBaseline() {
    let caps = Capabilities(
        chip: .appleSilicon(generation: 0),
        unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
        videoEncoderCount: 2,
        osVersion: .init(major: 26, minor: 0))
    let verdict = caps.tier(for: .programMode)
    #expect(verdict.tier == .baseline)
    #expect(verdict.reason.contains("Unknown"))
}

@Test("Program Mode: M2 with encoders resolves to pro")
func programModeM2Pro() {
    let caps = Capabilities(
        chip: .appleSilicon(generation: 2),
        unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
        videoEncoderCount: 2,
        osVersion: .init(major: 26, minor: 0))
    let verdict = caps.tier(for: .programMode)
    #expect(verdict.tier == .pro)
}

@Test("Program Mode: M1 with encoders resolves to accelerated")
func programModeM1Accelerated() {
    let caps = Capabilities(
        chip: .appleSilicon(generation: 1),
        unifiedMemoryBytes: 8 * 1024 * 1024 * 1024,
        videoEncoderCount: 1,
        osVersion: .init(major: 26, minor: 0))
    let verdict = caps.tier(for: .programMode)
    #expect(verdict.tier == .accelerated)
}
