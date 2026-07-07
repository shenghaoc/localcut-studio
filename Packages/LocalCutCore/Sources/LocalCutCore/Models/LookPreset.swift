import Foundation

/// Optional sidecar LUT reference for a look preset. The app may resolve this
/// relative to the preset file when sandbox access allows it.
public struct LookPresetLUTReference: Hashable, Codable, Sendable {
    public var relativePath: String
    public var displayName: String

    public init(relativePath: String, displayName: String) {
        self.relativePath = relativePath
        self.displayName = displayName
    }
}

/// A single ordered look node stored in `LookPresetV1`.
public enum LookPresetNode: Hashable, Codable, Sendable {
    case grain(GrainEffect)
    case halation(HalationEffect)
    case vignette(VignetteEffect)

    private enum CodingKeys: String, CodingKey {
        case effectName
        case params
    }

    public init?(effect: Effect) {
        switch effect {
        case .grain(let grain): self = .grain(grain)
        case .halation(let halation): self = .halation(halation)
        case .vignette(let vignette): self = .vignette(vignette)
        case .colourGrade, .lut, .skinSmooth: return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let effectName = try container.decode(String.self, forKey: .effectName)
        // The effect payloads use synthesized `Codable`, so their `clamp()` is
        // bypassed on decode. Clamp here so a shared/edited `.lclook` can never
        // feed out-of-range values (huge radius/redBoost/grain size) straight
        // into the Core Image filters during preview/export.
        switch effectName {
        case LookEffectKind.grain.rawValue:
            var grain = try container.decode(GrainEffect.self, forKey: .params)
            grain.clamp()
            self = .grain(grain)
        case LookEffectKind.halation.rawValue:
            var halation = try container.decode(HalationEffect.self, forKey: .params)
            halation.clamp()
            self = .halation(halation)
        case LookEffectKind.vignette.rawValue:
            var vignette = try container.decode(VignetteEffect.self, forKey: .params)
            vignette.clamp()
            self = .vignette(vignette)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .effectName,
                in: container,
                debugDescription: "Unsupported look effect '\(effectName)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .grain(let grain):
            try container.encode(LookEffectKind.grain.rawValue, forKey: .effectName)
            try container.encode(grain, forKey: .params)
        case .halation(let halation):
            try container.encode(LookEffectKind.halation.rawValue, forKey: .effectName)
            try container.encode(halation, forKey: .params)
        case .vignette(let vignette):
            try container.encode(LookEffectKind.vignette.rawValue, forKey: .effectName)
            try container.encode(vignette, forKey: .params)
        }
    }

    public var effect: Effect {
        switch self {
        case .grain(let grain): .grain(grain)
        case .halation(let halation): .halation(halation)
        case .vignette(let vignette): .vignette(vignette)
        }
    }
}

/// Portable JSON look preset used by Phase 38. It stores only look-pack nodes,
/// never the full clip state, so applying it preserves colour, LUT, skin-smooth,
/// transitions, and timing.
public struct LookPresetV1: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let fileExtension = "lclook"

    public var schemaVersion: Int
    public var name: String
    public var nodes: [LookPresetNode]
    public var lut: LookPresetLUTReference?

    public init(schemaVersion: Int = LookPresetV1.currentSchemaVersion,
                name: String,
                nodes: [LookPresetNode],
                lut: LookPresetLUTReference? = nil) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.nodes = nodes
        self.lut = lut
    }

    public init(name: String, effects: [Effect], lut: LookPresetLUTReference? = nil) {
        self.init(name: name, nodes: effects.compactMap(LookPresetNode.init(effect:)), lut: lut)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case nodes
        case lut
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? LookPresetV1.currentSchemaVersion
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Look"
        nodes = try container.decodeIfPresent([LookPresetNode].self, forKey: .nodes) ?? []
        lut = try container.decodeIfPresent(LookPresetLUTReference.self, forKey: .lut)
    }

    public var effects: [Effect] {
        nodes.map(\.effect)
    }

    public func applying(to chain: [Effect]) -> [Effect] {
        chain.applyingLookEffects(effects)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(LookPresetV1.self, from: data)
    }
}

/// Starter presets available without file I/O. The app exposes these in the
/// inspector and writes/imports the same `LookPresetV1` JSON shape for user
/// presets.
public enum LookPresetLibrary: Sendable {
    public static let builtInPresets: [LookPresetV1] = [
        preset("Clean Film", grain: 0.12, grainSize: 1.1, halation: 0.08, threshold: 0.78, radius: 12, vignette: 0.08),
        preset("Warm 16mm", grain: 0.22, grainSize: 1.8, halation: 0.28, threshold: 0.68, radius: 18, vignette: 0.18),
        preset("Cool Print", grain: 0.14, grainSize: 1.2, halation: 0.05, threshold: 0.82, radius: 10, vignette: 0.12),
        preset("Noir Matte", grain: 0.2, grainSize: 1.4, halation: 0.02, threshold: 0.9, radius: 8, vignette: 0.32),
        preset("Golden Hour", grain: 0.1, grainSize: 1.0, halation: 0.34, threshold: 0.62, radius: 24, vignette: 0.1),
        preset("Soft Commercial", grain: 0.06, grainSize: 0.8, halation: 0.14, threshold: 0.74, radius: 16, vignette: 0.05),
        preset("Night Glow", grain: 0.18, grainSize: 1.3, halation: 0.38, threshold: 0.58, radius: 28, vignette: 0.25),
        preset("Faded Stock", grain: 0.16, grainSize: 1.6, halation: 0.18, threshold: 0.72, radius: 14, vignette: -0.08),
        preset("Documentary", grain: 0.09, grainSize: 0.9, halation: 0.04, threshold: 0.84, radius: 8, vignette: 0.06),
        preset("Music Video", grain: 0.15, grainSize: 1.1, halation: 0.45, threshold: 0.55, radius: 34, vignette: 0.18),
    ]

    private static func preset(_ name: String,
                               grain: Float,
                               grainSize: Float,
                               halation: Float,
                               threshold: Float,
                               radius: Float,
                               vignette: Float) -> LookPresetV1 {
        LookPresetV1(
            name: name,
            nodes: [
                .halation(HalationEffect(
                    strength: Keyframed(defaultValue: halation),
                    threshold: threshold,
                    radius: radius,
                    redBoost: 0.9)),
                .vignette(VignetteEffect(
                    amount: Keyframed(defaultValue: vignette),
                    radius: 0.72,
                    softness: 0.35)),
                .grain(GrainEffect(
                    amount: Keyframed(defaultValue: grain),
                    size: grainSize,
                    monochrome: true,
                    seed: stableSeed(for: name))),
            ])
    }

    private static func stableSeed(for string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
