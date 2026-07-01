import Testing
import Foundation
@testable import LocalCutCore

@Suite("Scene model")
struct SceneModelTests {

    // MARK: - Codable round-trip

    @Test("SceneDoc Codable round-trip")
    func sceneDocCodableRoundTrip() throws {
        let layer = SceneLayer(
            sourceRef: .captureSource(UUID()),
            transform: Transform2D(translateX: 0.1, translateY: 0.2, scale: 1.5, rotation: 0),
            visible: true,
            zIndex: 2,
            opacity: 0.8)
        let scene = SceneDefinition(
            name: "PiP",
            hotkey: "1",
            layers: [layer])
        let doc = SceneDoc(schemaVersion: sceneSchemaVersion, scenes: [scene])

        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(SceneDoc.self, from: data)

        #expect(decoded.schemaVersion == doc.schemaVersion)
        #expect(decoded.scenes.count == 1)
        #expect(decoded.scenes[0].name == "PiP")
        #expect(decoded.scenes[0].hotkey == "1")
        #expect(decoded.scenes[0].layers.count == 1)
        #expect(decoded.scenes[0].layers[0].opacity == 0.8)
        #expect(decoded.scenes[0].layers[0].zIndex == 2)
    }

    @Test("SceneLayer sourceRef Codable — captureSource")
    func sceneLayerSourceRefCaptureSource() throws {
        let uuid = UUID()
        let ref = SceneSourceRef.captureSource(uuid)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(SceneSourceRef.self, from: data)
        #expect(decoded == ref)
    }

    @Test("SceneLayer sourceRef Codable — still")
    func sceneLayerSourceRefStill() throws {
        let uuid = UUID()
        let ref = SceneSourceRef.still(uuid)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(SceneSourceRef.self, from: data)
        #expect(decoded == ref)
    }

    @Test("SceneLayer sourceRef Codable — colour")
    func sceneLayerSourceRefColour() throws {
        let ref = SceneSourceRef.colour(hex: "#FF0000")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(SceneSourceRef.self, from: data)
        #expect(decoded == ref)
    }

    // MARK: - Migration

    @Test("Migration handles version 1")
    func migrationHandlesVersion1() {
        let doc = SceneDoc(schemaVersion: 1, scenes: [])
        let migrated = migrateSceneDoc(doc)
        #expect(migrated.schemaVersion == sceneSchemaVersion)
    }

    @Test("Migration preserves scenes")
    func migrationPreservesScenes() {
        let scene = SceneDefinition(name: "Test", layers: [])
        let doc = SceneDoc(schemaVersion: 1, scenes: [scene])
        let migrated = migrateSceneDoc(doc)
        #expect(migrated.scenes.count == 1)
        #expect(migrated.scenes[0].name == "Test")
    }

    // MARK: - Hotkey conflict detection

    @Test("No conflicts when hotkeys are unique")
    func noConflicts() {
        let scenes = [
            SceneDefinition(name: "A", hotkey: "1", layers: []),
            SceneDefinition(name: "B", hotkey: "2", layers: []),
        ]
        #expect(detectHotkeyConflicts(in: scenes).isEmpty)
    }

    @Test("Detects duplicate hotkeys")
    func detectsDuplicateHotkeys() {
        let scenes = [
            SceneDefinition(name: "A", hotkey: "1", layers: []),
            SceneDefinition(name: "B", hotkey: "1", layers: []),
            SceneDefinition(name: "C", hotkey: "2", layers: []),
        ]
        let conflicts = detectHotkeyConflicts(in: scenes)
        #expect(conflicts == ["1"])
    }

    @Test("Nil hotkeys do not conflict")
    func nilHotkeysNoConflict() {
        let scenes = [
            SceneDefinition(name: "A", hotkey: nil, layers: []),
            SceneDefinition(name: "B", hotkey: nil, layers: []),
        ]
        #expect(detectHotkeyConflicts(in: scenes).isEmpty)
    }

    @Test("Multiple conflicts detected")
    func multipleConflicts() {
        let scenes = [
            SceneDefinition(name: "A", hotkey: "1", layers: []),
            SceneDefinition(name: "B", hotkey: "1", layers: []),
            SceneDefinition(name: "C", hotkey: "2", layers: []),
            SceneDefinition(name: "D", hotkey: "2", layers: []),
        ]
        let conflicts = detectHotkeyConflicts(in: scenes)
        #expect(conflicts.sorted() == ["1", "2"])
    }

    // MARK: - resolveSceneAt

    @Test("Resolver sorts layers by z-index")
    func resolverSortsByZIndex() {
        let layers = [
            SceneLayer(sourceRef: .colour(hex: "#000"), zIndex: 3),
            SceneLayer(sourceRef: .colour(hex: "#FFF"), zIndex: 1),
            SceneLayer(sourceRef: .colour(hex: "#F00"), zIndex: 2),
        ]
        let scene = SceneDefinition(name: "Test", layers: layers)
        let resolved = resolveSceneAt(scenes: [scene], sceneId: scene.id)
        #expect(resolved.count == 3)
        #expect(resolved[0].zIndex == 1)
        #expect(resolved[1].zIndex == 2)
        #expect(resolved[2].zIndex == 3)
    }

    @Test("Invisible layers are excluded")
    func invisibleLayersExcluded() {
        let layers = [
            SceneLayer(sourceRef: .colour(hex: "#000"), visible: true, zIndex: 1),
            SceneLayer(sourceRef: .colour(hex: "#FFF"), visible: false, zIndex: 2),
        ]
        let scene = SceneDefinition(name: "Test", layers: layers)
        let resolved = resolveSceneAt(scenes: [scene], sceneId: scene.id)
        #expect(resolved.count == 1)
        #expect(resolved[0].zIndex == 1)
    }

    @Test("Missing scene returns empty")
    func missingSceneReturnsEmpty() {
        let scene = SceneDefinition(name: "Test", layers: [
            SceneLayer(sourceRef: .colour(hex: "#000"))
        ])
        let resolved = resolveSceneAt(scenes: [scene], sceneId: UUID())
        #expect(resolved.isEmpty)
    }

    @Test("Empty scene list returns empty")
    func emptySceneListReturnsEmpty() {
        let resolved = resolveSceneAt(scenes: [], sceneId: UUID())
        #expect(resolved.isEmpty)
    }

    // MARK: - Default scene

    @Test("Default scene returns first")
    func defaultSceneReturnsFirst() {
        let scenes = [
            SceneDefinition(name: "A", layers: []),
            SceneDefinition(name: "B", layers: []),
        ]
        #expect(resolveDefaultScene(scenes: scenes)?.name == "A")
    }

    @Test("Default scene returns nil for empty list")
    func defaultSceneNilForEmpty() {
        #expect(resolveDefaultScene(scenes: []) == nil)
    }

    // MARK: - ProjectDocument integration

    @Test("ProjectDocument includes sceneDoc")
    func projectDocumentIncludesSceneDoc() throws {
        let scene = SceneDefinition(name: "Full", layers: [
            SceneLayer(sourceRef: .captureSource(UUID()), zIndex: 0)
        ])
        let doc = ProjectDocument(
            name: "Test",
            renderWidth: 1920,
            renderHeight: 1080,
            frameRate: 30,
            media: [],
            videoTracks: [],
            audioTracks: [],
            sceneDoc: SceneDoc(scenes: [scene]))

        let data = try doc.encoded()
        let decoded = try ProjectDocument(data: data)
        #expect(decoded.sceneDoc.scenes.count == 1)
        #expect(decoded.sceneDoc.scenes[0].name == "Full")
    }

    @Test("Old documents without sceneDoc get empty default")
    func oldDocumentsGetEmptySceneDoc() throws {
        // Simulate an old document by encoding without sceneDoc key
        let json = """
        {"schemaVersion":9,"name":"Old","renderWidth":1920,"renderHeight":1080,"frameRate":30,"media":[],"videoTracks":[],"audioTracks":[]}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ProjectDocument.self, from: data)
        #expect(decoded.sceneDoc.scenes.isEmpty)
    }
}
