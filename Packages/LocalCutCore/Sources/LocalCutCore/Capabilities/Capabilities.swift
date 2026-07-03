import Foundation
import VideoToolbox

// MARK: - Tier

/// Three-tier ladder mirroring the browser-editor's P8/P26 model. `Comparable`
/// so a feature gate is a `>=` check rather than a switch.
public enum CapabilityTier: Int, Comparable, Sendable, Codable {
    case baseline = 0
    case accelerated = 1
    case pro = 2

    public static func < (lhs: CapabilityTier, rhs: CapabilityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Feature + verdict

/// Features that consume the capability resolver. The cases are the consumers
/// listed in `ROADMAP.md` open-infra row P26: frame interpolation (Phase 37),
/// simultaneous capture streams (Phase 41 + 45), and the Metal effect chain
/// (feature-colour-grading).
public enum CapabilityFeature: Sendable, Hashable {
    case frameInterpolation
    case simultaneousCaptureStreams(count: Int)
    case metalEffectChain
    /// Phase 45: Program Mode requires accelerated tier (hardware encoder +
    /// Apple Silicon or equivalent).
    case programMode
}

/// A tier choice with the human-readable reason behind it. Surfaced in the
/// Diagnostics panel (open-infra row P25) so a creator can tell why a feature
/// is degraded.
public struct CapabilityVerdict: Sendable, Hashable {
    public let tier: CapabilityTier
    public let reason: String

    public init(tier: CapabilityTier, reason: String) {
        self.tier = tier
        self.reason = reason
    }
}

// MARK: - Snapshot

/// Frozen view of what this Mac can do, captured once at editor launch. Value
/// type + `Sendable`, so every actor reads the same numbers without `await`.
public struct Capabilities: Sendable, Hashable {

    public enum ChipFamily: Sendable, Hashable {
        case intel
        /// `generation: 0` means Apple Silicon was detected but the board
        /// string didn't match any known M-series generation — the resolver
        /// treats it as baseline rather than guessing high.
        case appleSilicon(generation: Int)

        public var isAppleSilicon: Bool {
            if case .appleSilicon = self { return true } else { return false }
        }

        public var generation: Int? {
            if case .appleSilicon(let g) = self { return g } else { return nil }
        }
    }

    /// Major / minor / patch triple, stored directly rather than as
    /// `OperatingSystemVersion` so the snapshot stays trivially `Hashable`
    /// without leaning on a retroactive Foundation conformance.
    public struct OSVersion: Sendable, Hashable, Comparable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int = 0) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public init(_ os: OperatingSystemVersion) {
            self.major = os.majorVersion
            self.minor = os.minorVersion
            self.patch = os.patchVersion
        }

        public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    public let chip: ChipFamily
    public let unifiedMemoryBytes: UInt64
    public let videoEncoderCount: Int
    public let osVersion: OSVersion

    public var unifiedMemoryGiB: Double {
        Double(unifiedMemoryBytes) / (1024 * 1024 * 1024)
    }

    /// Editor-wide snapshot. Eager `static let` runs the probe on first access
    /// and caches the result for the process lifetime.
    public static let current: Capabilities = .probe()

    public init(chip: ChipFamily,
                unifiedMemoryBytes: UInt64,
                videoEncoderCount: Int,
                osVersion: OSVersion) {
        self.chip = chip
        self.unifiedMemoryBytes = unifiedMemoryBytes
        self.videoEncoderCount = videoEncoderCount
        self.osVersion = osVersion
    }
}

// MARK: - Probe

extension Capabilities {

    public static func probe() -> Capabilities {
        let chip = probeChipFamily()
        let memory = sysctlUInt64("hw.memsize") ?? 0
        let encoders = probeHardwareEncoderCount()
        let os = OSVersion(ProcessInfo.processInfo.operatingSystemVersion)
        return Capabilities(chip: chip,
                            unifiedMemoryBytes: memory,
                            videoEncoderCount: encoders,
                            osVersion: os)
    }

    private static func probeChipFamily() -> ChipFamily {
        let isAppleSilicon = sysctlInt("hw.optional.arm64") == 1
        guard isAppleSilicon else { return .intel }
        let board = sysctlString("hw.model") ?? ""
        return .appleSilicon(generation: appleSiliconGeneration(forBoard: board))
    }

    /// Maps the `hw.model` board string to an M-series generation. Apple ships
    /// a handful of board prefixes per generation; the table covers shipping
    /// Macs through M4. New boards land here on each Mac release. Unknown ⇒ 0,
    /// which the resolver treats as baseline.
    public static func appleSiliconGeneration(forBoard board: String) -> Int {
        let lower = board.lowercased()
        // The `Mac` family numbering is stable per generation. `Mac13` = M1,
        // `Mac14` = M2, `Mac15` = M3, `Mac16` = M4 (and Studio variants share
        // the family). `MacBookAir10,1` and friends are the original M1
        // entries — also generation 1.
        if lower.hasPrefix("mac16") { return 4 }
        if lower.hasPrefix("mac15") { return 3 }
        if lower.hasPrefix("mac14") { return 2 }
        if lower.hasPrefix("mac13") { return 1 }
        // Pre-`MacNN,X` board strings shipped on the original M1 line
        // (MacBookAir10,1, MacBookPro17/18,X, Macmini9,1, iMac21,X).
        if lower.hasPrefix("macbookair10")
            || lower.hasPrefix("macbookpro17")
            || lower.hasPrefix("macbookpro18")
            || lower.hasPrefix("macmini9")
            || lower.hasPrefix("imac21") {
            return 1
        }
        return 0
    }

    private static func probeHardwareEncoderCount() -> Int {
        // VTCopyVideoEncoderList doesn't expose a "hardware only" options-key
        // — the hardware flag is a per-entry property
        // (`kVTVideoEncoderList_IsHardwareAccelerated`). Pull the whole list
        // and count entries where the flag is set. On Intel Macs without a
        // hardware H.264/HEVC path none of the rows are hw-accelerated.
        var listRef: CFArray?
        let status = VTCopyVideoEncoderList(nil, &listRef)
        guard status == noErr, let list = listRef else { return 0 }
        let hwKey = kVTVideoEncoderList_IsHardwareAccelerated as String
        var hwCount = 0
        for entry in (list as NSArray) {
            guard let dict = entry as? [String: Any] else { continue }
            if (dict[hwKey] as? Bool) == true { hwCount += 1 }
        }
        return hwCount
    }
}

// MARK: - Decision API

extension Capabilities {

    /// Resolves the tier for a feature plus the reason behind it. Pure: the
    /// resolver inspects the snapshot in memory; no syscalls after launch.
    public func tier(for feature: CapabilityFeature) -> CapabilityVerdict {
        switch feature {
        case .frameInterpolation:
            return resolveFrameInterpolation()
        case .simultaneousCaptureStreams(let count):
            return resolveSimultaneousCaptureStreams(count: count)
        case .metalEffectChain:
            return resolveMetalEffectChain()
        case .programMode:
            return resolveProgramMode()
        }
    }

    private func resolveFrameInterpolation() -> CapabilityVerdict {
        // OS gate first — `VTFrameProcessor` is macOS 15.4+. Apple Silicon on
        // an older OS still resolves to baseline.
        if chip == .intel {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "VTFrameProcessor not available — Intel Mac")
        }
        if osVersion < Capabilities.OSVersion(major: 15, minor: 4) {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "VTFrameProcessor requires macOS 15.4+ (current: \(osVersionString))")
        }
        guard let generation = chip.generation, generation > 0 else {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "Unknown Apple Silicon generation — treating as baseline")
        }
        // Phase 37 reserves `.pro` (`preview-and-export`) for high-tier Apple
        // Silicon — M3 Pro/Max/Ultra and newer with the Neural Engine and
        // memory headroom for sustained 1080p. M1 and M2 always sit at
        // `.accelerated` (`export-only`); we approximate the Pro/Max/Ultra
        // split on M3+ via a unified-memory threshold of ≥ 24 GiB, since
        // sysctl doesn't expose the binned-die distinction directly.
        let memoryGiB = unifiedMemoryGiB
        if generation < 3 {
            return CapabilityVerdict(
                tier: .accelerated,
                reason: "VTFrameProcessor available — Apple Silicon M\(generation); "
                    + "pro tier requires M3 Pro/Max/Ultra+")
        }
        if memoryGiB < 24 {
            return CapabilityVerdict(
                tier: .accelerated,
                reason: "VTFrameProcessor available — Apple Silicon M\(generation); "
                    + "only \(Int(memoryGiB.rounded())) GiB unified memory "
                    + "(pro tier needs ≥ 24 GiB to approximate Pro/Max/Ultra)")
        }
        return CapabilityVerdict(
            tier: .pro,
            reason: "VTFrameProcessor available — Apple Silicon M\(generation) "
                + "Pro/Max/Ultra-class (≥ 24 GiB unified memory)")
    }

    private func resolveSimultaneousCaptureStreams(count requested: Int) -> CapabilityVerdict {
        guard requested > 0 else {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "No capture streams requested")
        }
        if chip == .intel {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "No hardware video encoder — Intel Mac")
        }
        if videoEncoderCount <= 0 {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "No hardware video encoders reported by VideoToolbox")
        }
        if requested > videoEncoderCount {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "Requested \(requested) streams but only "
                    + "\(videoEncoderCount) hardware encoder(s) available")
        }
        if requested >= 3 && unifiedMemoryGiB >= 16 {
            return CapabilityVerdict(
                tier: .pro,
                reason: "\(videoEncoderCount) hardware encoders; ≥ 16 GiB unified memory")
        }
        return CapabilityVerdict(
            tier: .accelerated,
            reason: "\(videoEncoderCount) hardware encoder(s); request for \(requested) fits")
    }

    private func resolveMetalEffectChain() -> CapabilityVerdict {
        if chip == .intel {
            // Intel Macs have a Metal-capable GPU but no unified memory; the
            // effect chain runs but loses zero-copy IOSurface ↔ texture, so we
            // call it baseline.
            return CapabilityVerdict(
                tier: .baseline,
                reason: "Metal effect chain runs on discrete GPU — no unified memory")
        }
        guard let generation = chip.generation, generation > 0 else {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "Unknown Apple Silicon generation — treating as baseline")
        }
        if unifiedMemoryGiB < 16 {
            return CapabilityVerdict(
                tier: .accelerated,
                reason: "Apple Silicon M\(generation); "
                    + "\(Int(unifiedMemoryGiB.rounded())) GiB unified memory")
        }
        return CapabilityVerdict(
            tier: .pro,
            reason: "Apple Silicon M\(generation); ≥ 16 GiB unified memory")
    }

    private func resolveProgramMode() -> CapabilityVerdict {
        // Program Mode requires hardware encoders and Apple Silicon (or
        // equivalent) for real-time multi-source capture + compositing.
        if chip == .intel {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "Program Mode requires Apple Silicon — Intel Mac")
        }
        if videoEncoderCount <= 0 {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "No hardware video encoders reported by VideoToolbox")
        }
        guard let generation = chip.generation, generation > 0 else {
            return CapabilityVerdict(
                tier: .baseline,
                reason: "Unknown Apple Silicon generation — treating as baseline")
        }
        // Minimum: accelerated tier. Pro tier for M2+ or ≥ 16 GiB.
        if generation >= 2 || unifiedMemoryGiB >= 16 {
            return CapabilityVerdict(
                tier: .pro,
                reason: "Apple Silicon M\(generation); "
                    + "\(videoEncoderCount) hardware encoder(s)")
        }
        return CapabilityVerdict(
            tier: .accelerated,
            reason: "Apple Silicon M\(generation); "
                + "\(videoEncoderCount) hardware encoder(s)")
    }

    private var osVersionString: String {
        "\(osVersion.major).\(osVersion.minor).\(osVersion.patch)"
    }
}

// MARK: - sysctl helpers

private func sysctlString(_ name: String) -> String? {
    var size: Int = 0
    if sysctlbyname(name, nil, &size, nil, 0) != 0 { return nil }
    guard size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    if sysctlbyname(name, &buffer, &size, nil, 0) != 0 { return nil }
    // `sysctlbyname` populates a NUL-terminated C string; truncate at the
    // first NUL byte so the resulting Swift string is clean.
    if let nul = buffer.firstIndex(of: 0) { buffer.removeSubrange(nul...) }
    return String(decoding: buffer, as: UTF8.self)
}

private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname(name, &value, &size, nil, 0) != 0 { return nil }
    return Int(value)
}

private func sysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    if sysctlbyname(name, &value, &size, nil, 0) != 0 { return nil }
    return value
}
