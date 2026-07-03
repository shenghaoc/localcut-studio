import Testing
import Foundation
import CoreMedia
import LocalCutCore

@Test("Capture manifest NDJSON round-trips typed records")
func captureManifestRoundTrip() throws {
    let sessionID = UUID()
    let sourceID = UUID()
    let source = CaptureSourceDescriptor(
        id: sourceID,
        kind: .display,
        displayName: "Display",
        relativePath: "screen.mov",
        width: 1920,
        height: 1080,
        frameRate: 30)
    let manifest = CaptureManifest(records: [
        .header(CaptureManifestHeader(
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: 1_800),
            sessionStartHostTimeUs: 1_000,
            sources: [source],
            encoders: [
                sourceID: CaptureEncoderConfig(codec: "h264", bitrate: 8_000_000, fragmentIntervalUs: 2_000_000),
            ])),
        .epoch(CaptureEpochRecord(atUs: 1_000, wallClock: Date(timeIntervalSince1970: 1_800))),
        .sourceEnded(CaptureSourceEndedRecord(
            sourceID: sourceID,
            atUs: 4_000_000,
            durationUs: 3_000_000,
            timelineStartUs: 20_000,
            sampleCount: 90)),
        .finalize(CaptureFinalizeRecord(atUs: 4_000_000, durationUs: 3_000_000)),
    ])

    let parsed = try CaptureManifest.parseNDJSON(manifest.encodeNDJSON())
    #expect(parsed.header?.sessionID == sessionID)
    #expect(parsed.isFinalized)
    #expect(parsed.recoveredSources.count == 1)
    #expect(parsed.recoveredSources[0].duration == CMTime(value: 3_000_000, timescale: 1_000_000))
    #expect(parsed.recoveredSources[0].descriptor.timelineStartUs == 20_000)
}

@Test("Capture manifest parser skips unknown kinds and truncated trailing lines")
func captureManifestSkipsUnknownAndTruncatedLines() throws {
    let sourceID = UUID()
    let source = CaptureSourceDescriptor(
        id: sourceID,
        kind: .microphone,
        displayName: "Mic",
        relativePath: "microphone.mov")
    let manifest = CaptureManifest(records: [
        .header(CaptureManifestHeader(
            sessionID: UUID(),
            createdAt: Date(timeIntervalSince1970: 2_000),
            sessionStartHostTimeUs: 10,
            sources: [source],
            encoders: [:])),
        .backpressure(CaptureBackpressureRecord(
            sourceID: sourceID,
            atUs: 20,
            droppedSamples: 3,
            reason: "writer input was not ready")),
    ])
    var data = try manifest.encodeNDJSON()
    data.append(#"{"kind":"scene-switch","sceneId":"intro","atUs":30}"#.data(using: .utf8)!)
    data.append(0x0A)
    data.append(#"{"kind":"finalize","atUs":"#.data(using: .utf8)!)

    let parsed = CaptureManifest.parseNDJSON(data)
    #expect(parsed.records.count == 2)
    #expect(!parsed.isFinalized)
    #expect(parsed.recoveredSources.count == 1)
    #expect(parsed.recoveredSources[0].droppedSamples == 3)
}

@Test("Capture manifest microsecond conversion clamps invalid time")
func captureManifestMicrosecondsClampInvalidTime() {
    #expect(CaptureManifest.microseconds(from: .invalid) == 0)
    let time = CMTime(seconds: 1.25, preferredTimescale: 600)
    #expect(CaptureManifest.microseconds(from: time) == 1_250_000)
}

// MARK: - Phase 45 manifest extension tests

@Test("Manifest parses old records (backward compatible)")
func manifestParsesOldRecords() throws {
    let sessionID = UUID()
    let sourceID = UUID()
    let source = CaptureSourceDescriptor(
        id: sourceID, kind: .display, displayName: "Screen", relativePath: "screen.mov")
    let manifest = CaptureManifest(records: [
        .header(CaptureManifestHeader(
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: 100),
            sessionStartHostTimeUs: 1000,
            sources: [source],
            encoders: [:])),
        .finalize(CaptureFinalizeRecord(atUs: 5000, durationUs: 4000)),
    ])
    let parsed = try CaptureManifest.parseNDJSON(manifest.encodeNDJSON())
    #expect(parsed.isFinalized)
    #expect(parsed.sceneDocRecords.isEmpty)
    #expect(parsed.sceneSwitchRecords.isEmpty)
}

@Test("Manifest skips unknown record kinds")
func manifestSkipsUnknownKinds() throws {
    var data = try CaptureManifest(records: [
        .header(CaptureManifestHeader(
            sessionID: UUID(),
            createdAt: Date(),
            sessionStartHostTimeUs: 0,
            sources: [],
            encoders: [:])),
    ]).encodeNDJSON()
    // Append an unknown kind.
    data.append(#"{"kind":"future-record","value":42}"#.data(using: .utf8)!)
    data.append(0x0A)
    let parsed = CaptureManifest.parseNDJSON(data)
    #expect(parsed.records.count == 1)
}

@Test("scene-doc round-trips")
func sceneDocRoundTrip() throws {
    let scene = SceneDefinition(name: "Full", layers: [
        SceneLayer(sourceRef: .captureSource(UUID()), zIndex: 0)
    ])
    let record = CaptureSceneDocRecord(atUs: 1000, scenes: SceneDoc(scenes: [scene]))
    let manifest = CaptureManifest(records: [.sceneDoc(record)])
    let parsed = try CaptureManifest.parseNDJSON(manifest.encodeNDJSON())
    #expect(parsed.sceneDocRecords.count == 1)
    #expect(parsed.sceneDocRecords[0].scenes.scenes.count == 1)
    #expect(parsed.sceneDocRecords[0].scenes.scenes[0].name == "Full")
    #expect(parsed.sceneDocRecords[0].atUs == 1000)
}

@Test("scene-switch round-trips")
func sceneSwitchRoundTrip() throws {
    let sceneId = UUID()
    let record = CaptureSceneSwitchRecord(sceneId: sceneId, atUs: 5000)
    let manifest = CaptureManifest(records: [.sceneSwitch(record)])
    let parsed = try CaptureManifest.parseNDJSON(manifest.encodeNDJSON())
    #expect(parsed.sceneSwitchRecords.count == 1)
    #expect(parsed.sceneSwitchRecords[0].sceneId == sceneId)
    #expect(parsed.sceneSwitchRecords[0].atUs == 5000)
}

@Test("Recovery uses latest preceding scene-doc")
func recoveryUsesLatestPrecedingSceneDoc() throws {
    let sceneA = SceneDefinition(name: "A", layers: [])
    let sceneB = SceneDefinition(name: "B", layers: [])
    let sceneId = sceneA.id

    let manifest = CaptureManifest(records: [
        .header(CaptureManifestHeader(
            sessionID: UUID(),
            createdAt: Date(),
            sessionStartHostTimeUs: 0,
            sources: [],
            encoders: [:])),
        .sceneDoc(CaptureSceneDocRecord(atUs: 100, scenes: SceneDoc(scenes: [sceneA]))),
        .sceneDoc(CaptureSceneDocRecord(atUs: 200, scenes: SceneDoc(scenes: [sceneB]))),
        .sceneSwitch(CaptureSceneSwitchRecord(sceneId: sceneId, atUs: 300)),
    ])
    let resolved = manifest.resolvedSceneSwitches
    #expect(resolved.count == 1)
    // Should use sceneB (the latest scene-doc before the switch).
    #expect(resolved[0].sceneDoc.scenes.first?.name == "B")
}

@Test("Recovery does not use current project scenes")
func recoveryDoesNotUseCurrentScenes() throws {
    let savedScene = SceneDefinition(name: "Saved", layers: [])
    let currentScene = SceneDefinition(name: "Current", layers: [])

    let manifest = CaptureManifest(records: [
        .sceneDoc(CaptureSceneDocRecord(atUs: 100, scenes: SceneDoc(scenes: [savedScene]))),
        .sceneSwitch(CaptureSceneSwitchRecord(sceneId: savedScene.id, atUs: 200)),
    ])
    let resolved = manifest.resolvedSceneSwitches
    #expect(resolved.count == 1)
    // The resolved scene-doc is from the manifest, not the "current" scenes.
    #expect(resolved[0].sceneDoc.scenes.first?.name == "Saved")
    // Verify it's different from what "current" scenes would give.
    #expect(resolved[0].sceneDoc.scenes.first?.name != currentScene.name)
}

@Test("Mid-session scene edit produces a later scene-doc")
func midSessionSceneEdit() throws {
    let sceneV1 = SceneDefinition(name: "V1", layers: [])
    var sceneV2 = SceneDefinition(name: "V2", layers: [])
    // Simulate editing: V2 gets a new layer.
    sceneV2.layers.append(SceneLayer(sourceRef: .colour(hex: "#000"), zIndex: 0))

    let manifest = CaptureManifest(records: [
        .sceneDoc(CaptureSceneDocRecord(atUs: 100, scenes: SceneDoc(scenes: [sceneV1]))),
        .sceneDoc(CaptureSceneDocRecord(atUs: 500, scenes: SceneDoc(scenes: [sceneV2]))),
        .sceneSwitch(CaptureSceneSwitchRecord(sceneId: sceneV2.id, atUs: 600)),
    ])
    let resolved = manifest.resolvedSceneSwitches
    #expect(resolved.count == 1)
    #expect(resolved[0].sceneDoc.scenes.first?.name == "V2")
    #expect(resolved[0].sceneDoc.scenes.first?.layers.count == 1)
}

@Test("Missing scene referenced by switch is handled safely")
func missingSceneHandledSafely() throws {
    let savedScene = SceneDefinition(name: "Saved", layers: [])
    let unknownSceneId = UUID() // Not in any scene-doc.

    let manifest = CaptureManifest(records: [
        .sceneDoc(CaptureSceneDocRecord(atUs: 100, scenes: SceneDoc(scenes: [savedScene]))),
        .sceneSwitch(CaptureSceneSwitchRecord(sceneId: unknownSceneId, atUs: 200)),
    ])
    let resolved = manifest.resolvedSceneSwitches
    #expect(resolved.count == 1)
    // The scene-doc is present but the sceneId doesn't match — this is
    // handled at the layout-landing layer, not in the manifest parser.
    #expect(resolved[0].sceneId == unknownSceneId)
}

@Test("scene-switch before any scene-doc yields no resolved switches")
func switchBeforeDocYieldsNothing() throws {
    let manifest = CaptureManifest(records: [
        .sceneSwitch(CaptureSceneSwitchRecord(sceneId: UUID(), atUs: 100)),
        .sceneDoc(CaptureSceneDocRecord(atUs: 200, scenes: SceneDoc())),
    ])
    let resolved = manifest.resolvedSceneSwitches
    #expect(resolved.isEmpty)
}
