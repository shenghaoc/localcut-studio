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
