import Foundation
import CoreGraphics

// MARK: - Scene schema version

/// Current scene document schema. Bump when the shape changes; migration
/// functions chain `V1→V2→…` to produce the current shape.
public let sceneSchemaVersion = 1

// MARK: - Scene source reference

/// Identifies which capture source backs a scene layer. The reference is
/// stable across sessions; the physical device binding (e.g. which webcam
/// serial number backs `sourceRef`) lives in app-local settings, NOT in
/// `ProjectDocument`.
public enum SceneSourceRef: Hashable, Codable, Sendable {
    /// References a capture source by its stable UUID (from the capture
    /// header's `CaptureSourceDescriptor.id`).
    case captureSource(UUID)
    /// A still image or title card embedded in the project.
    case still(UUID)
    /// A solid colour layer (useful for backgrounds).
    case colour(hex: String)
}

// MARK: - Scene layer

/// A single visual layer within a scene. Layers are composited bottom-to-top
/// sorted by `zIndex`.
public struct SceneLayer: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var sourceRef: SceneSourceRef
    /// Normalised transform (origin at centre, coordinates in ±0.5 range
    /// matching the existing `Transform2D` convention).
    public var transform: Transform2D
    /// Whether this layer is visible. Invisible layers are excluded from
    /// compositing but retained in the definition so the user can toggle
    /// them back without re-adding.
    public var visible: Bool
    /// Compositing order: lower values are behind higher values.
    public var zIndex: Int
    /// Per-layer opacity (0…1). Used for fade transitions and manual
    /// adjustment.
    public var opacity: Float

    public init(id: UUID = UUID(),
                sourceRef: SceneSourceRef,
                transform: Transform2D = .identity,
                visible: Bool = true,
                zIndex: Int = 0,
                opacity: Float = 1) {
        self.id = id
        self.sourceRef = sourceRef
        self.transform = transform
        self.visible = visible
        self.zIndex = zIndex
        self.opacity = opacity
    }
}

// MARK: - Scene definition

/// A named arrangement of layers with an optional hotkey for quick switching.
public struct SceneDefinition: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// Human-readable scene name (e.g. "Full screen", "PiP corner").
    public var name: String
    /// Keyboard hotkey character (e.g. "1", "a"). Nil means no hotkey.
    public var hotkey: String?
    /// The layers that make up this scene, sorted by `zIndex` on use.
    public var layers: [SceneLayer]

    public init(id: UUID = UUID(),
                name: String,
                hotkey: String? = nil,
                layers: [SceneLayer] = []) {
        self.id = id
        self.name = name
        self.hotkey = hotkey
        self.layers = layers
    }
}

// MARK: - Scene document

/// Top-level container persisted in `ProjectDocument`. Holds the schema
/// version for forward migration and the list of scene definitions.
public struct SceneDoc: Hashable, Codable, Sendable {
    public var schemaVersion: Int
    public var scenes: [SceneDefinition]

    public init(schemaVersion: Int = sceneSchemaVersion,
                scenes: [SceneDefinition] = []) {
        self.schemaVersion = schemaVersion
        self.scenes = scenes
    }
}

// MARK: - Migration

/// Applies a chain of schema upgrades to produce the current `SceneDoc` shape.
/// Every read of a scene doc from disk MUST pass through this function.
///
/// Current schema: V1 — no migration needed yet. The function exists as the
/// single entry point where future V2, V3, etc. upgrades will be added.
public func migrateSceneDoc(_ doc: SceneDoc) -> SceneDoc {
    var result = doc
    // V1 → V2 migration would go here when schemaVersion < 2.
    // Ensure the version is current after all migrations.
    result.schemaVersion = sceneSchemaVersion
    return result
}

// MARK: - Hotkey conflict detection

/// Returns an array of hotkey strings that appear in more than one scene.
/// Empty array means no conflicts.
public func detectHotkeyConflicts(in scenes: [SceneDefinition]) -> [String] {
    var seen: [String: Int] = [:]
    for scene in scenes {
        guard let hotkey = scene.hotkey else { continue }
        seen[hotkey, default: 0] += 1
    }
    return seen.filter { $0.value > 1 }.map(\.key).sorted()
}

// MARK: - Scene resolver

/// Pure function: resolves a scene at a given time by returning the layers
/// sorted by z-index, excluding invisible layers. Does NOT access devices,
/// settings, UI, or capture sessions.
///
/// - Parameters:
///   - scenes: The full scene list (after migration).
///   - sceneId: The scene to resolve.
/// - Returns: Layers sorted by `zIndex`, invisible layers excluded. Returns
///   an empty array if the scene ID is not found.
public func resolveSceneAt(scenes: [SceneDefinition],
                           sceneId: UUID) -> [SceneLayer] {
    guard let scene = scenes.first(where: { $0.id == sceneId }) else {
        return []
    }
    return scene.layers
        .filter { $0.visible }
        .sorted { $0.zIndex < $1.zIndex }
}

/// Resolves the first scene in the list (used as the default when no scene
/// has been selected yet). Returns nil if the list is empty.
public func resolveDefaultScene(scenes: [SceneDefinition]) -> SceneDefinition? {
    scenes.first
}
