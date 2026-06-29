import Testing
import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore
@testable import LocalCut_Studio

// MARK: - Pause/resume manifest records (T6.1)

@Suite("Recorder UX — Manifest pause/resume records")
struct ManifestPauseResumeTests {

    @Test("Pause record round-trips through encode/parse")
    func pauseRecordRoundTrip() throws {
        let manifest = CaptureManifest(records: [
            .pause(CapturePauseRecord(atUs: 5_000_000)),
        ])
        let data = try manifest.encodeNDJSON()
        let parsed = CaptureManifest.parseNDJSON(data)
        #expect(parsed.records.count == 1)
        if case .pause(let record) = parsed.records.first {
            #expect(record.atUs == 5_000_000)
        } else {
            Issue.record("Expected pause record")
        }
    }

    @Test("Resume record round-trips through encode/parse")
    func resumeRecordRoundTrip() throws {
        let manifest = CaptureManifest(records: [
            .resume(CaptureResumeRecord(atUs: 8_000_000)),
        ])
        let data = try manifest.encodeNDJSON()
        let parsed = CaptureManifest.parseNDJSON(data)
        #expect(parsed.records.count == 1)
        if case .resume(let record) = parsed.records.first {
            #expect(record.atUs == 8_000_000)
        } else {
            Issue.record("Expected resume record")
        }
    }

    @Test("Full session with pause/resume produces correct recovered sources")
    func fullSessionWithPauseResume() throws {
        let sourceID = UUID()
        let source = CaptureSourceDescriptor(
            id: sourceID,
            kind: .display,
            displayName: "Screen",
            relativePath: "screen.mov",
            width: 1920,
            height: 1080,
            frameRate: 30)
        let manifest = CaptureManifest(records: [
            .header(CaptureManifestHeader(
                sessionID: UUID(),
                createdAt: Date(),
                sessionStartHostTimeUs: 0,
                sources: [source],
                encoders: [:])),
            .sourceEnded(CaptureSourceEndedRecord(
                sourceID: sourceID,
                atUs: 3_000_000,
                durationUs: 3_000_000,
                timelineStartUs: 0,
                sampleCount: 90)),
            .pause(CapturePauseRecord(atUs: 3_000_000)),
            .resume(CaptureResumeRecord(atUs: 5_000_000)),
            .sourceEnded(CaptureSourceEndedRecord(
                sourceID: sourceID,
                atUs: 8_000_000,
                durationUs: 3_000_000,
                timelineStartUs: 5_000_000,
                sampleCount: 90)),
            .finalize(CaptureFinalizeRecord(atUs: 8_000_000, durationUs: 8_000_000)),
        ])

        let recovered = manifest.recoveredSources
        #expect(recovered.count == 1)
        // Two chunks aggregated: 3s + 3s = 6s total duration.
        let expectedDuration = CMTime(value: 6_000_000, timescale: CaptureManifest.microsecondTimescale)
        #expect(recovered[0].duration == expectedDuration)
        // Total samples: 90 + 90 = 180.
        #expect(recovered[0].sampleCount == 180)
        // Timeline start should be from the earliest chunk (0).
        #expect(recovered[0].descriptor.timelineStartUs == 0)
    }

    @Test("endedRecordsBySourceID groups multiple chunks per source")
    func endedRecordsGroupedBySource() throws {
        let sourceID = UUID()
        let source = CaptureSourceDescriptor(
            id: sourceID,
            kind: .display,
            displayName: "Screen",
            relativePath: "screen.mov")
        let manifest = CaptureManifest(records: [
            .header(CaptureManifestHeader(
                sessionID: UUID(),
                createdAt: Date(),
                sessionStartHostTimeUs: 0,
                sources: [source],
                encoders: [:])),
            .sourceEnded(CaptureSourceEndedRecord(
                sourceID: sourceID,
                atUs: 3_000_000,
                durationUs: 3_000_000,
                sampleCount: 90)),
            .sourceEnded(CaptureSourceEndedRecord(
                sourceID: sourceID,
                atUs: 8_000_000,
                durationUs: 3_000_000,
                sampleCount: 90)),
        ])

        let grouped = manifest.endedRecordsBySourceID
        #expect(grouped.count == 1)
        #expect(grouped[sourceID]?.count == 2)
    }
}

// MARK: - CaptureCoordinator pause/resume state (T6.1)

@Suite("CaptureCoordinator pause/resume state")
struct CoordinatorPauseResumeTests {

    @Test("Pause when not recording throws notRecording")
    func pauseWhenNotRecording() async {
        let coordinator = CaptureCoordinator()
        await #expect(throws: CaptureEngineError.notRecording) {
            try await coordinator.pause()
        }
    }

    @Test("Resume when not paused throws captureSessionFailed")
    func resumeWhenNotPaused() async {
        let coordinator = CaptureCoordinator()
        do {
            try await coordinator.resume()
            Issue.record("Expected captureSessionFailed")
        } catch {
            guard case CaptureEngineError.captureSessionFailed = error else {
                Issue.record("Expected captureSessionFailed, got \(error)")
                return
            }
        }
    }

    @Test("Stop from idle throws notRecording")
    func stopFromIdle() async {
        let coordinator = CaptureCoordinator()
        await #expect(throws: CaptureEngineError.notRecording) {
            _ = try await coordinator.stop()
        }
    }
}

// MARK: - PiP preset layout (T3.1)

@Suite("PiP preset layout")
struct PiPPresetLayoutTests {

    @Test("Bottom-right preset places origin at bottom-right corner")
    func bottomRightPlacement() {
        let preset = PiPPreset(corner: .bottomRight, size: .medium, mask: .roundedRect)
        let canvas = CGSize(width: 1920, height: 1080)
        let source = CGSize(width: 1280, height: 720)
        let layout = preset.layout(canvasSize: canvas, sourceSize: source)

        // Scale should be proportional to canvas height fraction.
        let expectedHeight = canvas.height * PiPSize.medium.heightFraction
        let expectedScale = expectedHeight / source.height
        #expect(abs(layout.scale - expectedScale) < 0.01)

        // X should be near the right edge minus inset.
        let expectedWidth = expectedHeight * (source.width / source.height)
        let expectedX = canvas.width - expectedWidth - preset.inset
        #expect(abs(layout.origin.x - expectedX) < 1)

        // Y should be near the bottom edge minus inset.
        let expectedY = canvas.height - expectedHeight - preset.inset
        #expect(abs(layout.origin.y - expectedY) < 1)
    }

    @Test("Top-left preset places origin at top-left corner")
    func topLeftPlacement() {
        let preset = PiPPreset(corner: .topLeft, size: .small, mask: .circle)
        let canvas = CGSize(width: 1920, height: 1080)
        let source = CGSize(width: 640, height: 480)
        let layout = preset.layout(canvasSize: canvas, sourceSize: source)

        #expect(abs(layout.origin.x - preset.inset) < 1)
        #expect(abs(layout.origin.y - preset.inset) < 1)
    }

    @Test("Standard presets all produce valid layouts")
    func standardPresetsValid() {
        let canvas = CGSize(width: 1920, height: 1080)
        let source = CGSize(width: 1280, height: 720)
        for preset in PiPPreset.standardPresets {
            let layout = preset.layout(canvasSize: canvas, sourceSize: source)
            #expect(layout.scale > 0)
            #expect(layout.origin.x >= 0)
            #expect(layout.origin.y >= 0)
        }
    }

    @Test("Preset clip geometry matches layout and mask")
    func presetClipGeometryMatchesLayout() {
        let preset = PiPPreset(corner: .bottomRight, size: .medium, mask: .roundedRect)
        let canvas = CGSize(width: 1920, height: 1080)
        let source = CGSize(width: 1280, height: 720)
        let layout = preset.layout(canvasSize: canvas, sourceSize: source)
        let geometry = preset.clipGeometry(canvasSize: canvas, sourceSize: source)

        let scaledSize = CGSize(width: source.width * layout.scale,
                                height: source.height * layout.scale)
        let expectedCenter = CGPoint(x: layout.origin.x + scaledSize.width / 2,
                                     y: layout.origin.y + scaledSize.height / 2)
        #expect(abs(geometry.positionOffset.width - (expectedCenter.x - canvas.width / 2)) < 1)
        #expect(abs(geometry.positionOffset.height - (expectedCenter.y - canvas.height / 2)) < 1)
        #expect(abs(geometry.scale - layout.scale) < 0.01)
        #expect(geometry.mask == .roundedRect)
    }
}

// MARK: - FrameScaler (T2.1)

@Suite("FrameScaler GPU scaling")
struct FrameScalerTests {

    @Test("Scale returns same buffer when dimensions match")
    func noScaleWhenMatching() {
        let scaler = FrameScaler(targetWidth: 320, targetHeight: 240)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let buffer = pb else {
            Issue.record("Could not create pixel buffer")
            return
        }
        let result = scaler.scale(buffer)
        // Should return the same buffer (identity).
        #expect(result === buffer)
    }

    @Test("Scale produces correct dimensions for different input size")
    func scaleProducesCorrectDimensions() {
        let scaler = FrameScaler(targetWidth: 640, targetHeight: 480)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let buffer = pb else {
            Issue.record("Could not create pixel buffer")
            return
        }
        guard let result = scaler.scale(buffer) else {
            Issue.record("Scaling returned nil")
            return
        }
        #expect(CVPixelBufferGetWidth(result) == 640)
        #expect(CVPixelBufferGetHeight(result) == 480)
    }

    @Test("Center crop includes scaled image origin")
    func centerCropIncludesScaledImageOrigin() {
        let crop = FrameScaler.centerCropRect(
            forScaledExtent: CGRect(x: 12, y: -8, width: 800, height: 600),
            targetWidth: 640,
            targetHeight: 480)

        #expect(crop.origin.x == 92)
        #expect(crop.origin.y == 52)
        #expect(crop.size == CGSize(width: 640, height: 480))
    }
}

// MARK: - Countdown state (T1.1)

@Suite("Countdown state management")
struct CountdownStateTests {

    @Test("Cancel countdown resets isCountdownActive")
    func cancelCountdown() {
        let model = EditorModel()
        model.isCountdownActive = true
        model.countdownRemaining = 3
        model.cancelCountdown()
        #expect(!model.isCountdownActive)
        #expect(model.countdownRemaining == 0)
        #expect(model.statusMessage == "Countdown cancelled.")
    }
}

// MARK: - Recording gap collapse (T1.3)

@Suite("Recording gap collapse")
@MainActor
struct RecordingGapCollapseTests {

    @Test("Collapse uses chronological order rather than storage order")
    func collapseUsesChronologicalOrder() {
        let model = EditorModel()
        let mediaID = UUID()
        let duration = CMTime(seconds: 2, preferredTimescale: 600)
        let first = Clip(mediaID: mediaID, sourceStart: .zero, duration: duration,
                         timelineStart: .zero)
        let second = Clip(mediaID: mediaID, sourceStart: .zero, duration: duration,
                          timelineStart: CMTime(seconds: 5, preferredTimescale: 600))
        let third = Clip(mediaID: mediaID, sourceStart: .zero, duration: duration,
                         timelineStart: CMTime(seconds: 12, preferredTimescale: 600))
        let unrelated = Clip(mediaID: mediaID, sourceStart: .zero, duration: duration,
                             timelineStart: CMTime(seconds: 30, preferredTimescale: 600))
        let track = Track(name: "Screen", kind: .video)
        track.clips = [second, unrelated, first, third]
        model.project.videoTracks = [track]
        model.lastRecordingSlots = [first, second, third].map { clip in
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .display, trackKind: .video, chunkIndex: 0),
                trackID: track.id,
                trackIndex: 0,
                clipID: clip.id,
                mediaID: clip.mediaID,
                timelineStart: clip.timelineStart)
        }

        model.collapseRecordingGap()

        let startsByID = Dictionary(uniqueKeysWithValues: track.clips.map { ($0.id, $0.timelineStart.seconds) })
        #expect(startsByID[first.id] == 0)
        #expect(startsByID[second.id] == 2)
        #expect(startsByID[third.id] == 4)
        #expect(startsByID[unrelated.id] == 30)
    }
}
