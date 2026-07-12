import Testing
import Foundation
import AppKit
import AVFoundation
import CoreMedia
import os
import LocalCutCore
import LocalCutDomain
@testable import LocalCutPlatform
@testable import LocalCut_Studio

nonisolated private final class RecorderSwitchingSession: CaptureRunningSession, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: ())
    private let switchable: Bool
    private let updateError: CaptureEngineError?
    private var _updatedTargets: [CaptureTarget] = []
    private var _excludedWindows: [CGWindowID] = []

    init(supportsSourceSwitching: Bool, updateError: CaptureEngineError? = nil) {
        self.switchable = supportsSourceSwitching
        self.updateError = updateError
    }

    nonisolated var supportsSourceSwitching: Bool { switchable }

    var updatedTargets: [CaptureTarget] {
        withLock { _updatedTargets }
    }

    var excludedWindows: [CGWindowID] {
        withLock { _excludedWindows }
    }

    func start() async throws {}

    func stop() async {}

    func updateTarget(_ newTarget: CaptureTarget) async throws {
        if let updateError {
            throw updateError
        }
        withLock {
            _updatedTargets.append(newTarget)
        }
    }

    func excludeWindow(_ windowID: CGWindowID) async throws {
        withLock {
            _excludedWindows.append(windowID)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.withLockUnchecked { _ in body() }
    }
}

// MARK: - Pause/resume manifest records (T6.1)

@Suite("Recorder UX — Manifest pause/resume records")
struct ManifestPauseResumeTests {

    struct RecordRoundTripCase: Sendable, CustomTestStringConvertible {
        let record: CaptureManifestRecord
        let expectedAtUs: Int64
        var testDescription: String {
            switch record {
            case .pause: "pause at \(expectedAtUs)us"
            case .resume: "resume at \(expectedAtUs)us"
            default: "record at \(expectedAtUs)us"
            }
        }
    }

    @Test("Record round-trips through encode/parse", arguments: [
        RecordRoundTripCase(record: .pause(CapturePauseRecord(atUs: 5_000_000)), expectedAtUs: 5_000_000),
        RecordRoundTripCase(record: .resume(CaptureResumeRecord(atUs: 8_000_000)), expectedAtUs: 8_000_000),
    ])
    func recordRoundTrip(_ testCase: RecordRoundTripCase) throws {
        let manifest = CaptureManifest(records: [testCase.record])
        let data = try manifest.encodeNDJSON()
        let parsed = CaptureManifest.parseNDJSON(data)
        #expect(parsed.records.count == 1)
        // Verify both the kind and the timestamp survive the round-trip.
        switch (testCase.record, parsed.records.first) {
        case (.pause, .pause(let record)):
            #expect(record.atUs == testCase.expectedAtUs)
        case (.resume, .resume(let record)):
            #expect(record.atUs == testCase.expectedAtUs)
        default:
            Issue.record("Record kind mismatch: expected \(testCase.record), got \(String(describing: parsed.records.first))")
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

    @Test("Unfinalized resumed sessions probe the open chunk without an ended record")
    func unfinalizedResumedSessionProbesOpenChunk() throws {
        let sourceID = UUID()
        let source = CaptureSourceDescriptor(
            id: sourceID,
            kind: .display,
            displayName: "Screen",
            relativePath: "screen.mov")
        let directoryURL = URL(filePath: "/tmp/LocalCutRecorderProbe", directoryHint: .isDirectory)
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
            .pause(CapturePauseRecord(atUs: 3_000_000)),
            .resume(CaptureResumeRecord(atUs: 5_000_000)),
        ])
        let result = CaptureSessionResult(
            id: UUID(),
            directoryURL: directoryURL,
            manifestURL: directoryURL.appendingPathComponent("manifest.ndjson"),
            manifest: manifest,
            wasRecovered: true)
        let recovered = try #require(result.manifest.recoveredSources.first)
        let existingURLs: Set<URL> = [
            directoryURL.appendingPathComponent("screen.mov"),
            directoryURL.appendingPathComponent("screen-1.mov"),
        ]

        let chunks = CaptureChunkResolver.chunks(for: recovered, result: result) { url in
            existingURLs.contains(url)
        }

        #expect(chunks.map(\.chunkIndex) == [0, 1])
        #expect(chunks[0].ended != nil)
        #expect(chunks[1].ended == nil)
        #expect(chunks[1].url.lastPathComponent == "screen-1.mov")
    }

    @Test("Capture session result exposes manifest finalization failures")
    func sessionResultManifestFinalizationFailure() {
        var result = CaptureSessionResult(
            id: UUID(),
            directoryURL: URL(filePath: "/tmp/LocalCutRecorderProbe", directoryHint: .isDirectory),
            manifestURL: URL(filePath: "/tmp/LocalCutRecorderProbe/manifest.ndjson"),
            manifest: CaptureManifest(),
            wasRecovered: false)

        #expect(!result.manifestFinalizeFailed)
        result.manifestFinalizationError = "Disk full"
        #expect(result.manifestFinalizeFailed)
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

// MARK: - Source switching routing (T2.1)

@Suite("CaptureCoordinator source-switch routing")
struct CoordinatorSourceSwitchRoutingTests {

    @Test("Source switching uses the first switch-capable session")
    func sourceSwitchingUsesFirstSwitchCapableSession() async throws {
        let passive = RecorderSwitchingSession(supportsSourceSwitching: false)
        let switching = RecorderSwitchingSession(supportsSourceSwitching: true)
        let target = CaptureTarget.window(
            windowID: 42,
            title: "Editor",
            owner: "LocalCut Studio",
            width: 1280,
            height: 720,
            frame: CGRect(x: 100, y: 120, width: 1280, height: 720))

        let didUpdate = try await CaptureCoordinator.updateFirstSwitchableSession(
            [passive, switching],
            to: target)

        #expect(didUpdate)
        #expect(passive.updatedTargets.isEmpty)
        #expect(switching.updatedTargets == [target])
    }

    @Test("Source switching reports no-op when no session supports switching")
    func sourceSwitchingReportsNoSwitchableSession() async throws {
        let passive = RecorderSwitchingSession(supportsSourceSwitching: false)
        let target = CaptureTarget.display(displayID: 1, width: 1920, height: 1080)

        let didUpdate = try await CaptureCoordinator.updateFirstSwitchableSession(
            [passive],
            to: target)

        #expect(!didUpdate)
        #expect(passive.updatedTargets.isEmpty)
    }

    @Test("Floating panel exclusion uses the switch-capable session")
    func floatingPanelExclusionUsesSwitchCapableSession() async throws {
        let passive = RecorderSwitchingSession(supportsSourceSwitching: false)
        let switching = RecorderSwitchingSession(supportsSourceSwitching: true)

        let didExclude = try await CaptureCoordinator.excludeWindowFromFirstSwitchableSession(
            [passive, switching],
            windowID: 99)

        #expect(didExclude)
        #expect(passive.excludedWindows.isEmpty)
        #expect(switching.excludedWindows == [99])
    }
}

// MARK: - PiP preset layout (T3.1)

@Suite("PiP preset layout")
struct PiPPresetLayoutTests {

    struct PlacementCase: Sendable, CustomTestStringConvertible {
        let preset: PiPPreset
        let canvas: CGSize
        let source: CGSize
        let expectedOriginX: CGFloat
        let expectedOriginY: CGFloat
        let expectedScale: CGFloat?
        var testDescription: String { "\(preset) \(Int(source.width))x\(Int(source.height))" }
    }

    nonisolated static let placementCases: [PlacementCase] = {
        let canvas = CGSize(width: 1920, height: 1080)

        // Bottom-right: medium, roundedRect, 1280x720 source
        let brPreset = PiPPreset(corner: .bottomRight, size: .medium, mask: .roundedRect)
        let brSource = CGSize(width: 1280, height: 720)
        let brExpectedHeight = canvas.height * PiPSize.medium.heightFraction
        let brExpectedScale = brExpectedHeight / brSource.height
        let brExpectedWidth = brExpectedHeight * (brSource.width / brSource.height)
        let brExpectedX = canvas.width - brExpectedWidth - brPreset.inset
        let brExpectedY = canvas.height - brExpectedHeight - brPreset.inset

        // Top-left: small, circle, 640x480 source
        let tlPreset = PiPPreset(corner: .topLeft, size: .small, mask: .circle)
        let tlSource = CGSize(width: 640, height: 480)

        return [
            PlacementCase(preset: brPreset, canvas: canvas, source: brSource,
                          expectedOriginX: brExpectedX, expectedOriginY: brExpectedY,
                          expectedScale: brExpectedScale),
            PlacementCase(preset: tlPreset, canvas: canvas, source: tlSource,
                          expectedOriginX: tlPreset.inset, expectedOriginY: tlPreset.inset,
                          expectedScale: nil),
        ]
    }()

    @Test("PiP preset places origin correctly", arguments: placementCases)
    func placement(_ testCase: PlacementCase) {
        let layout = testCase.preset.layout(canvasSize: testCase.canvas, sourceSize: testCase.source)

        #expect(abs(layout.origin.x - testCase.expectedOriginX) < 1)
        #expect(abs(layout.origin.y - testCase.expectedOriginY) < 1)
        if let expectedScale = testCase.expectedScale {
            #expect(abs(layout.scale - expectedScale) < 0.01)
        }
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

    @Test("Composition transform converts PiP Y offset to render coordinates")
    func compositionTransformConvertsPiPYOffset() {
        let preset = PiPPreset(corner: .bottomRight, size: .medium, mask: .roundedRect)
        let canvas = CGSize(width: 1920, height: 1080)
        let source = CGSize(width: 1280, height: 720)
        let layout = preset.layout(canvasSize: canvas, sourceSize: source)
        let geometry = preset.clipGeometry(canvasSize: canvas, sourceSize: source)
        let transform = CompositionBuilder.geometryTransform(
            naturalSize: source,
            preferredTransform: .identity,
            geometry: geometry,
            into: canvas)

        let renderedOrigin = CGPoint.zero.applying(transform)
        let scaledHeight = source.height * layout.scale
        let renderedTopY = canvas.height - renderedOrigin.y - scaledHeight
        #expect(abs(renderedOrigin.x - layout.origin.x) < 1)
        #expect(abs(renderedTopY - layout.origin.y) < 1)
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

// MARK: - Recorder mic meter (T4.2)

@Suite("Recorder mic meter")
struct RecorderMicMeterTests {

    @Test("Normalized peak reads float PCM samples")
    func normalizedPeakReadsFloatPCM() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channel = try #require(buffer.floatChannelData?[0])
        channel[0] = 0
        channel[1] = 0.25
        channel[2] = -0.5
        channel[3] = 0.1

        #expect(AVCaptureSampleSession.normalizedPeak(from: buffer) == 0.5)
    }
}

// MARK: - Region capture (T5.1)

@Suite("Region capture geometry")
struct RegionCaptureGeometryTests {

    @Test("Selection converts to top-left ScreenCaptureKit source rect")
    func selectionConvertsToSourceRect() throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 200, width: 640, height: 360)
        let region = try #require(CaptureRegion(
            displayID: 7,
            selectionInScreen: selection,
            screenFrame: screenFrame,
            displayPixelWidth: 2880,
            displayPixelHeight: 1800))

        #expect(region.displayID == 7)
        #expect(region.sourceRect == CGRect(x: 100, y: 340, width: 640, height: 360))
        #expect(region.outputWidth == 1280)
        #expect(region.outputHeight == 720)
    }

    @Test("Capture region applies only to matching display captures")
    func regionAppliesOnlyToMatchingDisplay() throws {
        let region = try #require(CaptureRegion(
            displayID: 7,
            selectionInScreen: CGRect(x: 100, y: 200, width: 640, height: 360),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            displayPixelWidth: 2880,
            displayPixelHeight: 1800))

        #expect(region.applies(to: .display(displayID: 7, width: 2880, height: 1800)))
        #expect(!region.applies(to: .display(displayID: 8, width: 2880, height: 1800)))
        #expect(!region.applies(to: .window(
            windowID: 11,
            title: "Window",
            owner: "App",
            width: 1280,
            height: 720,
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720))))
        #expect(!region.applies(to: .application(
            processID: 22,
            bundleIdentifier: "com.example.App",
            name: "App",
            displayID: 7,
            width: 1280,
            height: 720)))
    }

    @Test("Overlay geometry normalizes reversed drags")
    func overlayGeometryNormalizesReversedDrag() throws {
        let rect = try #require(RegionCaptureOverlayGeometry.selectionRect(
            start: CGPoint(x: 740, y: 560),
            current: CGPoint(x: 100, y: 200)))

        #expect(rect == CGRect(x: 100, y: 200, width: 640, height: 360))
    }

    @Test("Overlay geometry rejects tiny selections")
    func overlayGeometryRejectsTinySelections() {
        let region = RegionCaptureOverlayGeometry.captureRegion(
            selectionRect: CGRect(x: 10, y: 10, width: 12, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            displayID: 7,
            displayPixelWidth: 2880,
            displayPixelHeight: 1800)

        #expect(region == nil)
    }

    @Test("Overlay geometry returns nil until both drag endpoints exist")
    func overlayGeometryNilUntilDragEndpointsExist() {
        #expect(RegionCaptureOverlayGeometry.selectionRect(
            start: nil,
            current: CGPoint(x: 100, y: 200)) == nil)
        #expect(RegionCaptureOverlayGeometry.selectionRect(
            start: CGPoint(x: 100, y: 200),
            current: nil) == nil)
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

// MARK: - Replay buffer timeline insertion (Phase 46)

@Suite("Replay buffer timeline insertion")
@MainActor
struct ReplayBufferTimelineInsertionTests {

    @Test("Failed capture startup releases an enabled replay buffer")
    func failedCaptureStartupReleasesReplayBuffer() async throws {
        let model = EditorModel()
        let manager = ReplayBufferManager(sessionUUID: UUID())
        try await manager.enable()
        model.replayBufferManager = manager

        model.teardownReplayBuffer(manager)

        #expect(model.replayBufferManager == nil)
        #expect(!manager.isEnabled)
    }

    @Test("Multi-source replay clips land on separate aligned tracks")
    func multiSourceReplayClipsLandOnSeparateAlignedTracks() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayTimelineInsertion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let duration = CMTime(seconds: 1, preferredTimescale: 600)
        let offset = CMTime(seconds: 0.25, preferredTimescale: 600)
        let screenURL = try await makeVideoFixture(
            seconds: duration.seconds,
            in: directoryURL)
        let webcamURL = try await makeVideoFixture(
            seconds: duration.seconds,
            in: directoryURL)

        let model = EditorModel()
        model.currentTime = 4

        await model.insertReplayClips([
            ReplayBufferSavedClip(
                url: screenURL,
                duration: duration,
                timelineOffset: .zero,
                sourceFileURL: screenURL,
                mediaTypes: [.video]),
            ReplayBufferSavedClip(
                url: webcamURL,
                duration: duration,
                timelineOffset: offset,
                sourceFileURL: webcamURL,
                mediaTypes: [.video]),
        ])

        #expect(model.project.mediaItems.count == 2)
        #expect(model.project.videoTracks.count >= 2)
        let screenClip = try #require(model.project.videoTracks[0].clips.first)
        let webcamClip = try #require(model.project.videoTracks[1].clips.first)
        #expect(screenClip.mediaID != webcamClip.mediaID)
        #expect(screenClip.timelineStart == CMTime(seconds: 4, preferredTimescale: 600))
        #expect(webcamClip.timelineStart == CMTime(seconds: 4.25, preferredTimescale: 600))
        #expect(model.statusMessage.contains("Inserted 2 replay clips"))
        #expect(model.statusMessage.contains("at playhead"))
        #expect(model.undoTitle.contains("Insert Replay Clips"))

        model.undo()

        #expect(model.project.mediaItems.isEmpty)
        #expect(model.project.videoTracks.count == 1)
        #expect(model.project.videoTracks[0].clips.isEmpty)
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
        model.hasLastRecordingTake = true
        #expect(model.canCollapseRecordingGaps)

        model.collapseRecordingGap()

        let startsByID = Dictionary(uniqueKeysWithValues: track.clips.map { ($0.id, $0.timelineStart.seconds) })
        #expect(startsByID[first.id] == 0)
        #expect(startsByID[second.id] == 2)
        #expect(startsByID[third.id] == 4)
        #expect(startsByID[unrelated.id] == 30)
    }

    @Test("Collapse keeps simultaneous sources independent")
    func collapseKeepsSimultaneousSourcesIndependent() {
        let model = EditorModel()
        let duration = CMTime(seconds: 2, preferredTimescale: 600)
        let screenFirst = Clip(mediaID: UUID(), sourceStart: .zero, duration: duration,
                               timelineStart: .zero)
        let screenSecond = Clip(mediaID: UUID(), sourceStart: .zero, duration: duration,
                                timelineStart: CMTime(seconds: 5, preferredTimescale: 600))
        let webcamFirst = Clip(mediaID: UUID(), sourceStart: .zero, duration: duration,
                               timelineStart: .zero)
        let webcamSecond = Clip(mediaID: UUID(), sourceStart: .zero, duration: duration,
                                timelineStart: CMTime(seconds: 5, preferredTimescale: 600))
        let screenTrack = Track(name: "Screen", kind: .video)
        screenTrack.clips = [screenFirst, screenSecond]
        let webcamTrack = Track(name: "Webcam", kind: .video)
        webcamTrack.clips = [webcamFirst, webcamSecond]
        model.project.videoTracks = [screenTrack, webcamTrack]
        model.lastRecordingSlots = [
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .display, trackKind: .video, chunkIndex: 0),
                trackID: screenTrack.id,
                trackIndex: 0,
                clipID: screenFirst.id,
                mediaID: screenFirst.mediaID,
                timelineStart: screenFirst.timelineStart),
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .display, trackKind: .video, chunkIndex: 1),
                trackID: screenTrack.id,
                trackIndex: 0,
                clipID: screenSecond.id,
                mediaID: screenSecond.mediaID,
                timelineStart: screenSecond.timelineStart),
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .webcam, trackKind: .video, chunkIndex: 0),
                trackID: webcamTrack.id,
                trackIndex: 1,
                clipID: webcamFirst.id,
                mediaID: webcamFirst.mediaID,
                timelineStart: webcamFirst.timelineStart),
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .webcam, trackKind: .video, chunkIndex: 1),
                trackID: webcamTrack.id,
                trackIndex: 1,
                clipID: webcamSecond.id,
                mediaID: webcamSecond.mediaID,
                timelineStart: webcamSecond.timelineStart),
        ]

        model.collapseRecordingGap()

        #expect(screenTrack.clips[1].timelineStart.seconds == 2)
        #expect(webcamTrack.clips[1].timelineStart.seconds == 2)
    }

    @Test("Collapse without gaps does not register undo")
    func collapseWithoutGapsDoesNotRegisterUndo() {
        let model = EditorModel()
        let mediaID = UUID()
        let duration = CMTime(seconds: 2, preferredTimescale: 600)
        let first = Clip(mediaID: mediaID, sourceStart: .zero, duration: duration,
                         timelineStart: .zero)
        let second = Clip(mediaID: mediaID, sourceStart: .zero, duration: duration,
                          timelineStart: duration)
        let track = Track(name: "Screen", kind: .video)
        track.clips = [first, second]
        model.project.videoTracks = [track]
        model.lastRecordingSlots = [first, second].map { clip in
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .display, trackKind: .video, chunkIndex: 0),
                trackID: track.id,
                trackIndex: 0,
                clipID: clip.id,
                mediaID: clip.mediaID,
                timelineStart: clip.timelineStart)
        }
        model.hasLastRecordingTake = true

        model.collapseRecordingGap()

        #expect(model.statusMessage == "No recording gaps to collapse.")
        #expect(!model.canUndo)
    }

    @Test("Retake availability requires a stored request and idle recorder")
    func retakeAvailabilityRequiresRequestAndIdleRecorder() {
        let model = EditorModel()
        model.hasLastRecordingTake = true
        #expect(!model.canRetakeRecording)

        model.lastRecordingRequest = CaptureStartRequest(
            target: nil,
            includeSystemAudio: true,
            webcamDeviceID: nil,
            microphoneDeviceID: nil,
            rootURL: URL(filePath: "/tmp/LocalCutRecorderProbe", directoryHint: .isDirectory),
            frameRate: 30,
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600),
            capabilities: Capabilities.current)
        #expect(model.canRetakeRecording)

        model.isStartingRecording = true
        #expect(!model.canRetakeRecording)
    }

    @Test("Retake track indices are keyed per recording slot")
    func retakeTrackIndicesKeyedPerSlot() {
        let model = EditorModel()
        let screenTrack = Track(name: "Screen", kind: .video)
        let webcamTrack = Track(name: "Webcam", kind: .video)
        let systemAudioTrack = Track(name: "System Audio", kind: .audio)
        let micTrack = Track(name: "Microphone", kind: .audio)
        model.project.videoTracks = [screenTrack, webcamTrack]
        model.project.audioTracks = [systemAudioTrack, micTrack]
        let slots = [
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .display, trackKind: .video, chunkIndex: 0),
                trackID: screenTrack.id,
                trackIndex: 0,
                clipID: UUID(),
                mediaID: UUID(),
                timelineStart: .zero),
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .webcam, trackKind: .video, chunkIndex: 0),
                trackID: webcamTrack.id,
                trackIndex: 1,
                clipID: UUID(),
                mediaID: UUID(),
                timelineStart: .zero),
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .systemAudio, trackKind: .audio, chunkIndex: 0),
                trackID: systemAudioTrack.id,
                trackIndex: 0,
                clipID: UUID(),
                mediaID: UUID(),
                timelineStart: .zero),
            RecordingSlot(
                key: RecordingSlotKey(sourceKind: .microphone, trackKind: .audio, chunkIndex: 0),
                trackID: micTrack.id,
                trackIndex: 1,
                clipID: UUID(),
                mediaID: UUID(),
                timelineStart: .zero),
        ]

        let indices = model.currentTrackIndicesBySlot(slots)

        #expect(indices[slots[0].key] == 0)
        #expect(indices[slots[1].key] == 1)
        #expect(indices[slots[2].key] == 0)
        #expect(indices[slots[3].key] == 1)
    }

    @Test("Retake landing undo and redo restore timeline and recorder slots")
    func retakeLandingUndoRedoRestoresTimelineAndRecorderSlots() async throws {
        let model = EditorModel()
        let duration = CMTime(seconds: 1, preferredTimescale: 600)
        let previousStart = CMTime(seconds: 7, preferredTimescale: 600)
        let previousMedia = MediaItem(url: URL(filePath: "/tmp/previous-recording.mov"))
        previousMedia.duration = duration
        previousMedia.hasVideo = true
        let previousClip = Clip(
            mediaID: previousMedia.id,
            sourceStart: .zero,
            duration: duration,
            timelineStart: previousStart)
        let previousTrack = Track(name: "Previous Screen", kind: .video)
        previousTrack.clips = [previousClip]
        model.project.mediaItems = [previousMedia]
        model.project.videoTracks = [previousTrack]
        model.project.audioTracks = []

        let key = RecordingSlotKey(sourceKind: .display, trackKind: .video, chunkIndex: 0)
        let previousSlot = RecordingSlot(
            key: key,
            trackID: previousTrack.id,
            trackIndex: 0,
            clipID: previousClip.id,
            mediaID: previousMedia.id,
            timelineStart: previousStart)
        model.lastRecordingSlots = [previousSlot]
        model.hasLastRecordingTake = true
        let beforeRetake = model.captureState()

        model.project.mediaItems = []
        model.project.videoTracks = []
        model.lastRecordingSlots = []
        model.hasLastRecordingTake = false
        model.retakeUndoBefore = beforeRetake
        model.retakePreviousSlots = [previousSlot]
        model.retakeTimelinePositions = [key: previousStart]
        model.retakeTrackIndices = [key: 0]

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetakeUndoRedo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        // Create fixture at the path the resolver expects (screen.mov).
        // Retry on transient AVFoundation resource contention under parallel load.
        let fixtureURL = directoryURL.appendingPathComponent("screen.mov")
        var fixtureCreated = false
        for attempt in 0..<3 {
            do {
                let url = try await makeVideoFixture(seconds: duration.seconds, in: directoryURL)
                // Rename to the path CaptureChunkResolver expects.
                try? FileManager.default.removeItem(at: fixtureURL)
                try FileManager.default.moveItem(at: url, to: fixtureURL)
                fixtureCreated = true
                break
            } catch {
                if attempt == 2 { throw error }
                try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
            }
        }
        try #require(fixtureCreated, "Failed to create video fixture after 3 attempts")
        let sourceID = UUID()
        let source = CaptureSourceDescriptor(
            id: sourceID,
            kind: .display,
            displayName: "Display 1",
            relativePath: "screen.mov",
            width: 64,
            height: 64,
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
                atUs: 1_000_000,
                durationUs: 1_000_000,
                timelineStartUs: 0,
                sampleCount: 30)),
            .finalize(CaptureFinalizeRecord(atUs: 1_000_000, durationUs: 1_000_000)),
        ])
        let result = CaptureSessionResult(
            id: UUID(),
            directoryURL: directoryURL,
            manifestURL: directoryURL.appendingPathComponent("manifest.ndjson"),
            manifest: manifest,
            wasRecovered: false)

        let landed = await model.landCaptureSession(result)

        #expect(landed)
        #expect(model.statusMessage == "Retake added to timeline.")
        #expect(model.undoTitle.contains("Retake Recording"))
        let replacementMediaID = try #require(model.project.mediaItems.first?.id)
        let replacementSlots = model.lastRecordingSlots
        #expect(replacementSlots.count == 1)
        #expect(replacementSlots.first?.timelineStart == previousStart)
        #expect(model.project.videoTracks.first?.clips.first?.timelineStart == previousStart)

        model.undo()

        #expect(model.project.mediaItems.map(\.id) == [previousMedia.id])
        #expect(model.project.videoTracks.first?.clips.map(\.id) == [previousClip.id])
        #expect(model.lastRecordingSlots == [previousSlot])
        #expect(model.hasLastRecordingTake)
        #expect(model.canRedo)

        model.redo()

        #expect(model.project.mediaItems.map(\.id) == [replacementMediaID])
        #expect(model.lastRecordingSlots == replacementSlots)
        #expect(model.hasLastRecordingTake)
        #expect(model.project.videoTracks.first?.clips.first?.timelineStart == previousStart)
    }
}

// MARK: - Recording transport error handling

@Suite("Recording transport error handling")
@MainActor
struct RecordingTransportErrorHandlingTests {

    @Test("Pause error from stale coordinator state resets recording UI")
    func pauseErrorFromStaleCoordinatorStateResetsRecordingUI() async {
        let model = EditorModel()
        model.isRecording = true
        model.recordingMicLevel = 0.5

        await model.pauseRecording()

        #expect(!model.isRecording)
        #expect(!model.isPaused)
        #expect(!model.isPausingRecording)
        #expect(model.recordingMicLevel == 0)
        #expect(model.statusMessage == "Could not pause: No recording is running.")
    }

    @Test("Resume error is surfaced while keeping paused state retryable")
    func resumeErrorKeepsPausedStateRetryable() async {
        let model = EditorModel()
        model.isPaused = true

        await model.resumeRecording()

        #expect(model.isPaused)
        #expect(!model.isRecording)
        #expect(!model.isStartingRecording)
        #expect(model.statusMessage == "Could not resume: Capture failed: No paused recording to resume.")
    }

    @Test("Stop error clears stale recording UI state")
    func stopErrorClearsStaleRecordingUIState() async throws {
        let model = EditorModel()
        model.isRecording = true
        model.recordingStartedAt = Date()
        model.recordingElapsedSeconds = 12
        model.recordingDiskFreeBytes = 100
        model.recordingDiskWarning = .warn
        model.recordingSourceCount = 2
        model.recordingBackpressureCount = 1
        model.recordingIncludesMicrophone = true
        model.recordingMicLevel = 0.8

        model.stopRecording()
        for _ in 0..<50 where model.isStoppingRecording {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.isStoppingRecording)
        #expect(!model.isRecording)
        #expect(!model.isPaused)
        #expect(model.recordingStartedAt == nil)
        #expect(model.recordingElapsedSeconds == 0)
        #expect(model.recordingDiskFreeBytes == nil)
        #expect(model.recordingDiskWarning == nil)
        #expect(model.recordingSourceCount == 0)
        #expect(model.recordingBackpressureCount == 0)
        #expect(!model.recordingIncludesMicrophone)
        #expect(model.recordingMicLevel == 0)
        #expect(model.statusMessage == "No recording is running.")
    }
}

// MARK: - Recording document command guards

@Suite("Recording document command guards")
@MainActor
struct RecordingDocumentCommandGuardTests {

    enum CloseBlocker: CaseIterable, Sendable, CustomTestStringConvertible {
        case paused
        case countdown
        case starting
        case pausing
        case stopping

        var testDescription: String {
            switch self {
            case .paused: "paused"
            case .countdown: "countdown"
            case .starting: "starting"
            case .pausing: "pausing"
            case .stopping: "stopping"
            }
        }

        func setup(model: EditorModel) {
            switch self {
            case .paused: model.isPaused = true
            case .countdown: model.isCountdownActive = true
            case .starting: model.isStartingRecording = true
            case .pausing: model.isPausingRecording = true
            case .stopping: model.isStoppingRecording = true
            }
        }

        var expectedMessage: String {
            switch self {
            case .paused: return "Resume and stop the recording before closing the window."
            case .countdown: return "Cancel the countdown before closing the window."
            case .starting: return "Wait for the recording to start before closing the window."
            case .pausing: return "Finish pausing the recording before closing the window."
            case .stopping: return "Finish stopping the recording before closing the window."
            }
        }
    }

    @Test("Window close is blocked during recording transitions", arguments: CloseBlocker.allCases)
    func closeBlocked(blocker: CloseBlocker) {
        let model = EditorModel()
        let window = NSWindow()
        blocker.setup(model: model)

        #expect(model.confirmClose(window: window) == false)
        #expect(model.statusMessage == blocker.expectedMessage)
    }
}

// MARK: - Floating-panel fallback (R7.2)

@Suite("Floating-panel fallback")
@MainActor
struct FloatingPanelFallbackTests {

    @Test("Main-window recording state is independent of floating panel visibility")
    func mainWindowStateIndependentOfPanel() {
        let model = EditorModel()
        model.isRecording = true
        model.isPaused = false
        model.floatingPanelController.hide()
        #expect(model.isRecording)
        #expect(!model.isPaused)
    }

    @Test("Hide-while-recording defaults to false")
    func hideWhileRecordingDefaultsToFalse() {
        let model = EditorModel()
        #expect(!model.hideFloatingPanelWhileRecording)
    }

    @Test("Floating panel show/hide/close lifecycle does not affect recording state")
    func panelLifecycleDoesNotAffectRecording() {
        let model = EditorModel()
        model.isRecording = true
        model.recordingSourceCount = 1
        model.recordingMicLevel = 0.3

        model.floatingPanelController.show(model: model)
        #expect(model.floatingPanelController.isShown)
        #expect(model.isRecording)

        model.floatingPanelController.hide()
        #expect(!model.floatingPanelController.isShown)
        #expect(model.isRecording)
        #expect(model.recordingSourceCount == 1)
        #expect(model.recordingMicLevel == 0.3)

        model.floatingPanelController.close()
        #expect(!model.floatingPanelController.isShown)
        #expect(model.isRecording)
    }
}
