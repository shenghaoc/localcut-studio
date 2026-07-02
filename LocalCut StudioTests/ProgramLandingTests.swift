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
            sessionStartHostTimeUs: 0,
            sessionDuration: duration)
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
            sessionStartHostTimeUs: 0,
            sessionDuration: duration)
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
            sessionStartHostTimeUs: 0,
            sessionDuration: duration)
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
            sessionStartHostTimeUs: 0,
            sessionDuration: duration)
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
            sessionStartHostTimeUs: 0,
            sessionDuration: CMTime(value: 10, timescale: 1))
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
            sessionStartHostTimeUs: 0,
            sessionDuration: duration)
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
            sessionStartHostTimeUs: 0,
            sessionDuration: duration)
        // The clip's snapshot is from the scene-doc, not the "current" scenes.
        #expect(clips[0].sceneSnapshot.name == "Saved")
    }

    @Test("Host-time scene switches are normalized to session-relative layout clips")
    func hostTimeSwitchesNormalize() {
        let sceneA = SceneDefinition(name: "A", layers: [])
        let sceneB = SceneDefinition(name: "B", layers: [])
        let sceneDoc = SceneDoc(scenes: [sceneA, sceneB])
        let duration = CMTime(value: 10, timescale: 1)
        let sessionStartUs: Int64 = 1_000_000_000

        let switches: [(sceneId: UUID, atUs: Int64, sceneDoc: SceneDoc)] = [
            (sceneId: sceneA.id, atUs: sessionStartUs, sceneDoc: sceneDoc),
            (sceneId: sceneB.id, atUs: sessionStartUs + 4_000_000, sceneDoc: sceneDoc),
        ]

        let clips = ProgramLanding.buildLayoutClips(
            switches: switches,
            sessionStartHostTimeUs: sessionStartUs,
            sessionDuration: duration)

        #expect(clips.count == 2)
        #expect(clips[0].timelineStart.value == 0)
        #expect(clips[0].duration.value == 4 * 600)
        #expect(clips[1].timelineStart.value == 4 * 600)
        #expect(clips[1].duration.value == 6 * 600)
    }

    @Test("Landing creates media items for ISO clips")
    @MainActor
    func landingCreatesMediaItemsForISOClips() {
        let model = EditorModel()
        let sourceID = UUID()
        let scene = SceneDefinition(name: "Full", layers: [
            SceneLayer(sourceRef: .captureSource(sourceID), zIndex: 0)
        ])
        let sceneDoc = SceneDoc(scenes: [scene])
        let durationUs: Int64 = 5_000_000
        let manifest = CaptureManifest(records: [
            .header(CaptureManifestHeader(
                sessionID: UUID(),
                createdAt: Date(timeIntervalSince1970: 0),
                sessionStartHostTimeUs: 1_000,
                sources: [
                    CaptureSourceDescriptor(
                        id: sourceID,
                        kind: .display,
                        displayName: "Display",
                        relativePath: "display.mov",
                        width: 1920,
                        height: 1080,
                        frameRate: 30),
                ],
                encoders: [:])),
            .sceneDoc(CaptureSceneDocRecord(atUs: 1_000, scenes: sceneDoc)),
            .sceneSwitch(CaptureSceneSwitchRecord(sceneId: scene.id, atUs: 1_000)),
            .sourceEnded(CaptureSourceEndedRecord(
                sourceID: sourceID,
                atUs: 1_000 + durationUs,
                durationUs: durationUs,
                sampleCount: 10)),
            .finalize(CaptureFinalizeRecord(atUs: 1_000 + durationUs, durationUs: durationUs)),
        ])
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgramLanding-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = ProgramSessionResult(
            sessionID: UUID(),
            sessionURL: fileURL.deletingLastPathComponent(),
            manifest: manifest,
            isoTrackURLs: [sourceID: fileURL],
            duration: CaptureManifest.time(fromMicroseconds: durationUs),
            sceneSwitches: manifest.resolvedSceneSwitches)

        ProgramLanding.land(result: result, model: model)

        #expect(model.project.mediaItems.contains(where: { $0.id == sourceID }))
        #expect(model.project.videoTracks.last?.clips.first?.mediaID == sourceID)
        #expect(model.project.layoutTracks.last?.clips.count == 1)
    }
}
