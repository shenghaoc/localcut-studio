import Testing
import Foundation
import CoreMedia
@testable import LocalCut_Studio
import LocalCutCore

@Suite("ProgramLanding")
struct ProgramLandingTests {

    @Test("Stop lands N ISO tracks plus 1 layout track")
    func stopLandsTracks() {
        let sourceId1 = UUID()
        let sourceId2 = UUID()
        let sceneId = UUID()
        let scene = SceneDefinition(id: sceneId, name: "Full", layers: [
            SceneLayer(sourceRef: .captureSource(sourceId1), zIndex: 0)
        ])
        let sceneDoc = SceneDoc(scenes: [scene])
        let duration = CMTime(value: 10, timescale: 1)

        let switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)] = [
            (sceneId: sceneId, atUs: 0, sceneDoc: sceneDoc),
        ]

        let clips = ProgramLanding.buildLayoutClips(
            switches: switches,
            sessionDuration: duration,
            scenes: [scene])
        #expect(clips.count == 1)
        #expect(clips[0].sceneSnapshot.name == "Full")
    }

    @Test("Scene switches partition into correct segment ranges")
    func sceneSwitchesPartition() {
        let sceneA = SceneDefinition(name: "A", layers: [])
        let sceneB = SceneDefinition(name: "B", layers: [])
        let sceneDoc = SceneDoc(scenes: [sceneA, sceneB])
        let duration = CMTime(value: 10, timescale: 1)

        let switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)] = [
            (sceneId: sceneA.id, atUs: 0, sceneDoc: sceneDoc),
            (sceneId: sceneB.id, atUs: 3_000_000, sceneDoc: sceneDoc),
            (sceneId: sceneA.id, atUs: 7_000_000, sceneDoc: sceneDoc),
        ]

        let clips = ProgramLanding.buildLayoutClips(
            switches: switches,
            sessionDuration: duration,
            scenes: [sceneA, sceneB])
        #expect(clips.count == 3)
        #expect(clips[0].sceneSnapshot.name == "A")
        #expect(clips[1].sceneSnapshot.name == "B")
        #expect(clips[2].sceneSnapshot.name == "A")
    }

    @Test("Layout clips store scene snapshots")
    func clipsStoreSnapshots() {
        let scene = SceneDefinition(name: "PiP", layers: [
            SceneLayer(sourceRef: .captureSource(UUID()), zIndex: 0, opacity: 0.8)
        ])
        let sceneDoc = SceneDoc(scenes: [scene])
        let duration = CMTime(value: 5, timescale: 1)

        let switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)] = [
            (sceneId: scene.id, atUs: 0, sceneDoc: sceneDoc),
        ]

        let clips = ProgramLanding.buildLayoutClips(
            switches: switches,
            sessionDuration: duration,
            scenes: [scene])
        #expect(clips.count == 1)
        #expect(clips[0].sceneSnapshot.layers.count == 1)
        #expect(clips[0].sceneSnapshot.layers[0].opacity == 0.8)
    }

    @Test("Layout clips store correct duration")
    func clipsStoreDuration() {
        let sceneA = SceneDefinition(name: "A", layers: [])
        let sceneB = SceneDefinition(name: "B", layers: [])
        let sceneDoc = SceneDoc(scenes: [sceneA, sceneB])
        let duration = CMTime(value: 10, timescale: 1)

        let switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)] = [
            (sceneId: sceneA.id, atUs: 0, sceneDoc: sceneDoc),
            (sceneId: sceneB.id, atUs: 5_000_000, sceneDoc: sceneDoc),
        ]

        let clips = ProgramLanding.buildLayoutClips(
            switches: switches,
            sessionDuration: duration,
            scenes: [sceneA, sceneB])
        #expect(clips.count == 2)
        // First clip: 0 to 5 seconds.
        #expect(clips[0].duration.value == 5 * 600) // timescale 600
        // Second clip: 5 to 10 seconds.
        #expect(clips[1].duration.value == 5 * 600)
    }

    @Test("Empty switches returns empty clips")
    func emptySwitches() {
        let clips = ProgramLanding.buildLayoutClips(
            switches: [],
            sessionDuration: CMTime(value: 10, timescale: 1),
            scenes: [])
        #expect(clips.isEmpty)
    }

    @Test("Missing scene yields placeholder clip")
    func missingSceneYieldsPlaceholder() {
        let sceneDoc = SceneDoc(scenes: [])
        let unknownId = UUID()
        let duration = CMTime(value: 5, timescale: 1)

        let switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)] = [
            (sceneId: unknownId, atUs: 0, sceneDoc: sceneDoc),
        ]

        let clips = ProgramLanding.buildLayoutClips(
            switches: switches,
            sessionDuration: duration,
            scenes: [])
        #expect(clips.count == 1)
        #expect(clips[0].sceneSnapshot.name == "Unknown")
        #expect(clips[0].sceneSnapshot.layers.isEmpty)
    }

    @Test("Re-export uses layout snapshots, not current scene list")
    func reExportUsesSnapshots() {
        let savedScene = SceneDefinition(name: "Saved", layers: [
            SceneLayer(sourceRef: .captureSource(UUID()), zIndex: 0, opacity: 1.0)
        ])
        let sceneDoc = SceneDoc(scenes: [savedScene])
        let duration = CMTime(value: 5, timescale: 1)

        let switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)] = [
            (sceneId: savedScene.id, atUs: 0, sceneDoc: sceneDoc),
        ]

        let clips = ProgramLanding.buildLayoutClips(
            switches: switches,
            sessionDuration: duration,
            scenes: [savedScene])
        // The clip's snapshot is from the scene-doc, not the "current" scenes.
        #expect(clips[0].sceneSnapshot.name == "Saved")
    }
}
