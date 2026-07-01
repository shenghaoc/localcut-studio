import Testing
import Foundation
import CoreMedia
@testable import LocalCut_Studio
import LocalCutCore

@Suite("ProgramRecovery")
struct ProgramRecoveryTests {

    @Test("Mocked kill mid-session recovers partial session")
    func mockedKillRecovers() {
        let scene = SceneDefinition(name: "Full", layers: [])
        let sceneDoc = SceneDoc(scenes: [scene])
        let manifest = CaptureManifest(records: [
            .header(CaptureManifestHeader(
                sessionID: UUID(),
                createdAt: Date(),
                sessionStartHostTimeUs: 0,
                sources: [],
                encoders: [:])),
            .sceneDoc(CaptureSceneDocRecord(atUs: 0, scenes: sceneDoc)),
            .sceneSwitch(CaptureSceneSwitchRecord(sceneId: scene.id, atUs: 1_000_000)),
            // No finalize — simulating crash.
        ])
        #expect(ProgramRecovery.hasProgramData(manifest: manifest))
    }

    @Test("Recovery reconstructs layout from manifest records")
    func recoveryReconstructsLayout() {
        let scene = SceneDefinition(name: "Test", layers: [])
        let sceneDoc = SceneDoc(scenes: [scene])
        let manifest = CaptureManifest(records: [
            .sceneDoc(CaptureSceneDocRecord(atUs: 0, scenes: sceneDoc)),
            .sceneSwitch(CaptureSceneSwitchRecord(sceneId: scene.id, atUs: 0)),
        ])
        let duration = CMTime(value: 5, timescale: 1)
        let clips = ProgramRecovery.reconstructLayout(manifest: manifest, sessionDuration: duration)
        #expect(clips?.count == 1)
        #expect(clips?.first?.sceneSnapshot.name == "Test")
    }

    @Test("Recovery uses preceding scene-doc snapshots")
    func recoveryUsesPrecedingSnapshots() {
        let sceneV1 = SceneDefinition(name: "V1", layers: [])
        let sceneV2 = SceneDefinition(name: "V2", layers: [])
        let manifest = CaptureManifest(records: [
            .sceneDoc(CaptureSceneDocRecord(atUs: 0, scenes: SceneDoc(scenes: [sceneV1]))),
            .sceneDoc(CaptureSceneDocRecord(atUs: 500_000, scenes: SceneDoc(scenes: [sceneV2]))),
            .sceneSwitch(CaptureSceneSwitchRecord(sceneId: sceneV2.id, atUs: 600_000)),
        ])
        let duration = CMTime(value: 5, timescale: 1)
        let clips = ProgramRecovery.reconstructLayout(manifest: manifest, sessionDuration: duration)
        #expect(clips?.count == 1)
        #expect(clips?.first?.sceneSnapshot.name == "V2")
    }

    @Test("Recovery ignores current edited scenes")
    func recoveryIgnoresCurrentScenes() {
        let savedScene = SceneDefinition(name: "Saved", layers: [])
        let sceneDoc = SceneDoc(scenes: [savedScene])
        let manifest = CaptureManifest(records: [
            .sceneDoc(CaptureSceneDocRecord(atUs: 0, scenes: sceneDoc)),
            .sceneSwitch(CaptureSceneSwitchRecord(sceneId: savedScene.id, atUs: 0)),
        ])
        let duration = CMTime(value: 5, timescale: 1)
        let clips = ProgramRecovery.reconstructLayout(manifest: manifest, sessionDuration: duration)
        // The recovered layout uses "Saved", not whatever the user has now.
        #expect(clips?.first?.sceneSnapshot.name == "Saved")
    }

    @Test("Unresolvable scene yields recovery issue, not crash")
    func unresolvableSceneNoCrash() {
        let sceneDoc = SceneDoc(scenes: []) // Empty — no scenes.
        let unknownId = UUID()
        let manifest = CaptureManifest(records: [
            .header(CaptureManifestHeader(
                sessionID: UUID(),
                createdAt: Date(),
                sessionStartHostTimeUs: 0,
                sources: [],
                encoders: [:])),
            .sceneDoc(CaptureSceneDocRecord(atUs: 0, scenes: sceneDoc)),
            .sceneSwitch(CaptureSceneSwitchRecord(sceneId: unknownId, atUs: 1_000_000)),
        ])

        // Create a temporary directory for the recovery test.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = CaptureSessionResult(
            id: UUID(),
            directoryURL: dir,
            manifestURL: dir.appendingPathComponent("manifest.ndjson"),
            manifest: manifest,
            wasRecovered: true)

        let recovery = ProgramRecovery.recover(from: result, rootURL: dir)
        #expect(recovery != nil)
        #expect(recovery?.issues.count == 1)
        if case .unresolvableScene(let sceneId, _) = recovery?.issues.first {
            #expect(sceneId == unknownId)
        } else {
            Issue.record("Expected unresolvableScene issue")
        }
    }

    @Test("Non-program manifest returns nil for program recovery")
    func nonProgramManifestReturnsNil() {
        let manifest = CaptureManifest(records: [
            .header(CaptureManifestHeader(
                sessionID: UUID(),
                createdAt: Date(),
                sessionStartHostTimeUs: 0,
                sources: [],
                encoders: [:])),
            .finalize(CaptureFinalizeRecord(atUs: 5000, durationUs: 5000)),
        ])
        #expect(!ProgramRecovery.hasProgramData(manifest: manifest))
    }

    @Test("Multiple scene switches yield multiple layout clips")
    func multipleSwitchesMultipleClips() {
        let sceneA = SceneDefinition(name: "A", layers: [])
        let sceneB = SceneDefinition(name: "B", layers: [])
        let sceneDoc = SceneDoc(scenes: [sceneA, sceneB])
        let manifest = CaptureManifest(records: [
            .sceneDoc(CaptureSceneDocRecord(atUs: 0, scenes: sceneDoc)),
            .sceneSwitch(CaptureSceneSwitchRecord(sceneId: sceneA.id, atUs: 0)),
            .sceneSwitch(CaptureSceneSwitchRecord(sceneId: sceneB.id, atUs: 3_000_000)),
        ])
        let duration = CMTime(value: 10, timescale: 1)
        let clips = ProgramRecovery.reconstructLayout(manifest: manifest, sessionDuration: duration)
        #expect(clips?.count == 2)
        #expect(clips?[0].sceneSnapshot.name == "A")
        #expect(clips?[1].sceneSnapshot.name == "B")
    }
}
