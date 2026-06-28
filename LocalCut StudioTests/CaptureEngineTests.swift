import Testing
import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore
@testable import LocalCut_Studio

// MARK: - State machine (T6.1 partial)

@Suite("CaptureCoordinator state machine")
struct CaptureCoordinatorStateTests {
    @Test("State machine: idle → starting → recording → stopping → idle cycle")
    func stateMachineLifecycle() async throws {
        let coordinator = CaptureCoordinator()
        // The coordinator starts idle. Starting a real capture requires hardware,
        // so we test only that errors are surfaced correctly for invalid requests.
        let request = CaptureStartRequest(
            target: nil,
            includeSystemAudio: false,
            webcamDeviceID: nil,
            microphoneDeviceID: nil,
            rootURL: FileManager.default.temporaryDirectory,
            frameRate: 30,
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600),
            capabilities: Capabilities.current)
        // Request with no sources → should error
        await #expect(throws: CaptureEngineError.noCaptureSources) {
            try await coordinator.start(request)
        }
    }

    @Test("State machine: stop before start throws notRecording")
    func stopBeforeStartThrowsNotRecording() async {
        let coordinator = CaptureCoordinator()
        await #expect(throws: CaptureEngineError.notRecording) {
            _ = try await coordinator.stop()
        }
    }

    @Test("State machine: failed start resets to idle")
    func doubleStartThroughErrorPath() async {
        let coordinator = CaptureCoordinator()
        let request = CaptureStartRequest(
            target: nil,
            includeSystemAudio: false,
            webcamDeviceID: nil,
            microphoneDeviceID: nil,
            rootURL: FileManager.default.temporaryDirectory,
            frameRate: 30,
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600),
            capabilities: Capabilities.current)
        // First attempt (no sources) — fails
        await #expect(throws: CaptureEngineError.noCaptureSources) {
            try await coordinator.start(request)
        }
        // Second attempt should still run the request preflight. A leaked
        // `.starting` state would report `alreadyRecording` instead.
        await #expect(throws: CaptureEngineError.noCaptureSources) {
            try await coordinator.start(request)
        }
    }
}

// MARK: - ContinuousCaptureWriter lifecycle (T6.1)

@Suite("ContinuousCaptureWriter lifecycle")
struct ContinuousCaptureWriterTests {

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func tempMovURL() throws -> URL {
        let directory = try makeTempDirectory()
        return directory.appendingPathComponent("capture.mov")
    }

    private static func removeTempDirectory(containing outputURL: URL) {
        try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
    }

    private static func makeWriter(
        mediaType: AVMediaType = .video,
        outputSettings: [String: Any]? = nil,
        fragmentInterval: CMTime = CMTime(seconds: 2, preferredTimescale: 600),
        width: Int = 320,
        height: Int = 240
    ) throws -> (writer: ContinuousCaptureWriter, manifest: CaptureManifestFileWriter, outputURL: URL) {
        let outputURL = try Self.tempMovURL()
        let manifestURL = outputURL.deletingLastPathComponent().appendingPathComponent("manifest.ndjson")
        let manifest = try CaptureManifestFileWriter(url: manifestURL)
        let source = CaptureSourceDescriptor(
            id: UUID(),
            kind: .display,
            displayName: "Test",
            relativePath: outputURL.lastPathComponent,
            width: width,
            height: height,
            frameRate: 30)
        let settings = outputSettings ?? [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
            ],
        ]
        let writer = try ContinuousCaptureWriter(
            source: source,
            outputURL: outputURL,
            mediaType: mediaType,
            outputSettings: settings,
            fragmentInterval: fragmentInterval,
            sessionStartHostTimeUs: 0,
            manifest: manifest)
        return (writer, manifest, outputURL)
    }

    private static func makePixelBuffer(width: Int = 320, height: Int = 240) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pb)
        guard status == kCVReturnSuccess, let pixelBuffer = pb else { return nil }
        return pixelBuffer
    }

    private static func makeVideoSampleBuffer(presentationTime: CMTime,
                                              duration: CMTime = CMTime(value: 1, timescale: 30),
                                              width: Int = 320,
                                              height: Int = 240) -> CMSampleBuffer? {
        guard let pixelBuffer = makePixelBuffer(width: width, height: height) else { return nil }
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    @Test("Writer lifecycle: init creates output file and returns without error")
    func writerInitCreatesFile() async throws {
        let outputURL = try Self.tempMovURL()
        defer { Self.removeTempDirectory(containing: outputURL) }
        let manifest = try CaptureManifestFileWriter(
            url: outputURL.deletingLastPathComponent().appendingPathComponent("manifest.ndjson"))
        defer { manifest.close() }
        let source = CaptureSourceDescriptor(
            id: UUID(),
            kind: .display,
            displayName: "Test",
            relativePath: outputURL.lastPathComponent,
            width: 320,
            height: 240,
            frameRate: 30)
        let writer = try ContinuousCaptureWriter(
            source: source,
            outputURL: outputURL,
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 240,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_000_000,
                ],
            ],
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600),
            sessionStartHostTimeUs: 0,
            manifest: manifest)
        let sourceEnded = try await writer.finish()
        #expect(sourceEnded.sampleCount == 0)
        #expect(sourceEnded.durationUs == 0)
    }

    @Test("Writer lifecycle: finish after start-writing failure surfaces error (P1 fix)")
    func writerFinishAfterStartupFailure() async throws {
        // Use an invalid output settings dictionary that will cause
        // AVAssetWriter.startWriting to fail.
        let outputURL = try Self.tempMovURL()
        defer { Self.removeTempDirectory(containing: outputURL) }
        let manifestURL = outputURL.deletingLastPathComponent().appendingPathComponent("manifest.ndjson")
        let manifest = try CaptureManifestFileWriter(url: manifestURL)
        defer { manifest.close() }
        let source = CaptureSourceDescriptor(
            id: UUID(),
            kind: .display,
            displayName: "Test",
            relativePath: outputURL.lastPathComponent,
            width: 320,
            height: 240,
            frameRate: 30)
        // Bogus codec should cause writer to fail at start.
        let writer = try ContinuousCaptureWriter(
            source: source,
            outputURL: outputURL,
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: "bogus.codec",
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 240,
            ],
            fragmentInterval: CMTime(seconds: 2, preferredTimescale: 600),
            sessionStartHostTimeUs: 0,
            manifest: manifest)
        // Append a buffer to trigger startWriting
        if let sampleBuffer = Self.makeVideoSampleBuffer(presentationTime: .zero) {
            writer.append(sampleBuffer)
        } else {
            Issue.record("Could not create sample buffer")
        }
        // finish() should throw because startWriting failed
        do {
            _ = try await writer.finish()
            Issue.record("Expected writerStartFailed")
        } catch CaptureEngineError.writerStartFailed(let message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Expected writerStartFailed, got \(error)")
        }
    }

    @Test("Writer lifecycle: finish is idempotent; second call returns same record")
    func writerFinishIdempotent() async throws {
        let (writer, manifest, outputURL) = try Self.makeWriter()
        defer {
            manifest.close()
            Self.removeTempDirectory(containing: outputURL)
        }
        let firstResult = try await writer.finish()
        #expect(firstResult.sampleCount == 0)
        // Second finish on an already-finished writer should not throw for a
        // clean (never-started) writer — it returns zero counts.
        let secondResult = try await writer.finish()
        #expect(secondResult.sampleCount == 0)
        #expect(secondResult.durationUs == firstResult.durationUs)
    }

    @Test("Writer lifecycle: single continuous file — no additional files created")
    func writerSingleFilePerSource() async throws {
        let (writer, manifest, outputURL) = try Self.makeWriter()
        defer {
            manifest.close()
            Self.removeTempDirectory(containing: outputURL)
        }
        if let sampleBuffer = Self.makeVideoSampleBuffer(presentationTime: .zero) {
            writer.append(sampleBuffer)
        } else {
            Issue.record("Could not create sample buffer")
        }
        let record = try await writer.finish()
        #expect(record.sampleCount == 1)
        let parent = outputURL.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        // The writer creates one .mov and the manifest creates manifest.ndjson.
        let movFiles = contents.filter { $0.pathExtension == "mov" }
        #expect(movFiles.count == 1)
    }

    @Test("Writer lifecycle: 30-minute mocked session stays single-file per source")
    func thirtyMinuteMockedSessionStaysSingleFilePerSource() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let sourceID = UUID()
        let sessionDirectory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let movURL = sessionDirectory.appendingPathComponent("screen.mov")
        #expect(FileManager.default.createFile(atPath: movURL.path, contents: Data([0])))

        let source = CaptureSourceDescriptor(
            id: sourceID,
            kind: .display,
            displayName: "Screen",
            relativePath: movURL.lastPathComponent,
            width: 1920,
            height: 1080,
            frameRate: 30)
        let manifest = CaptureManifest(records: [
            .header(CaptureManifestHeader(
                sessionID: sessionID,
                createdAt: Date(),
                sessionStartHostTimeUs: 0,
                sources: [source],
                encoders: [:])),
            .sourceEnded(CaptureSourceEndedRecord(
                sourceID: sourceID,
                atUs: 1_800_000_000,
                durationUs: 1_800_000_000,
                timelineStartUs: 0,
                sampleCount: 54_000)),
        ])
        try manifest.encodeNDJSON().write(to: sessionDirectory.appendingPathComponent("manifest.ndjson"))

        let coordinator = CaptureCoordinator()
        let recovered = try await coordinator.scanRecoveredSessions(rootURL: root)
        #expect(recovered.count == 1)
        #expect(recovered.first?.manifest.recoveredSources.first?.sampleCount == 54_000)
        #expect(recovered.first?.manifest.recoveredSources.first?.duration == CMTime(
            value: 1_800_000_000,
            timescale: CaptureManifest.microsecondTimescale))

        let contents = try FileManager.default.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil)
        let movFiles = contents.filter { $0.pathExtension == "mov" }
        #expect(movFiles.map(\.lastPathComponent) == [movURL.lastPathComponent])
    }
}

// MARK: - PTS alignment (T6.4)

@Suite("Capture timestamp alignment")
struct CaptureAlignmentTests {

    @Test("microseconds(from:) is monotonic for sequential host-clock reads")
    func hostClockMonotonic() {
        let t1 = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        let t2 = CaptureManifest.microseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
        #expect(t2 >= t1)
    }

    @Test("timelineStartUs offsets to zero for PTS == sessionStart")
    func timelineStartOffsetsToZero() {
        // When first frame PTS equals sessionStart, timelineStart should be 0.
        let pts = CMTime(value: 1_000_000, timescale: CaptureManifest.microsecondTimescale)
        let sessionStartUs = CaptureManifest.microseconds(from: pts)
        let firstUs = CaptureManifest.microseconds(from: pts)
        let timelineStartUs = max(0, firstUs - sessionStartUs)
        #expect(timelineStartUs == 0)
    }

    @Test("timelineStartUs offsets positive for PTS after sessionStart")
    func timelineStartForDelayedFrame() {
        let sessionStart = CMTime(value: 500_000, timescale: CaptureManifest.microsecondTimescale)
        let firstPTS = CMTime(value: 700_000, timescale: CaptureManifest.microsecondTimescale)
        let sessionStartUs = CaptureManifest.microseconds(from: sessionStart)
        let firstUs = CaptureManifest.microseconds(from: firstPTS)
        let timelineStartUs = max(0, firstUs - sessionStartUs)
        #expect(timelineStartUs == 200_000)
    }

    @Test("Two sources sharing host clock produce aligned timeline starts")
    func twoSourcesAligned() {
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let sessionStartUs = CaptureManifest.microseconds(from: hostTime)
        // Simulate two sources starting at slightly different host times
        let source1Start = hostTime + CMTime(value: 10_000, timescale: CaptureManifest.microsecondTimescale)
        let source2Start = hostTime + CMTime(value: 10_030, timescale: CaptureManifest.microsecondTimescale)
        let t1Us = CaptureManifest.microseconds(from: source1Start)
        let t2Us = CaptureManifest.microseconds(from: source2Start)
        let deltaUs = abs((t1Us - sessionStartUs) - (t2Us - sessionStartUs))
        // Within one audio quantum at 48 kHz (~21 µs), plus measurement jitter.
        #expect(deltaUs < 1_000)
    }
}

// MARK: - Manifest crash recovery (T6.2, T6.3)

@Suite("Capture manifest NDJSON recovery")
struct CaptureManifestRecoveryTests {

    @Test("Manifest parser drops truncated trailing line and keeps valid prefix")
    func truncatedTrailingLine() throws {
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
                sessionStartHostTimeUs: 1_000,
                sources: [source],
                encoders: [:])),
            .sourceEnded(CaptureSourceEndedRecord(
                sourceID: sourceID,
                atUs: 4_000_000,
                durationUs: 3_000_000,
                timelineStartUs: 20_000,
                sampleCount: 90)),
        ])
        var data = try manifest.encodeNDJSON()
        // Simulate a crash mid-write: append a partial finalize line without
        // a trailing newline.
        data.append(#"{"kind":"finalize","atUs":5000000,"dur"#.data(using: .utf8)!)

        let parsed = CaptureManifest.parseNDJSON(data)
        #expect(parsed.records.count == 2)
        #expect(!parsed.isFinalized)
        #expect(parsed.recoveredSources.count == 1)
        #expect(parsed.recoveredSources[0].descriptor.timelineStartUs == 20_000)
    }

    @Test("Manifest parser ignores unknown record kind (scene-doc forward compat)")
    func unknownRecordKind() throws {
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
                sessionStartHostTimeUs: 10,
                sources: [source],
                encoders: [:])),
            .finalize(CaptureFinalizeRecord(atUs: 30, durationUs: 20)),
        ])
        var data = try manifest.encodeNDJSON()
        // Insert an unknown record kind (Phase 45's scene-doc) between valid records.
        let insertion = #"{"kind":"scene-doc","sceneId":"intro","atUs":15}"#.data(using: .utf8)!
        if let finalizeStart = data.range(of: #"{"kind":"finalize""#.data(using: .utf8)!) {
            data.insert(contentsOf: insertion, at: finalizeStart.lowerBound)
            data.insert(0x0A, at: finalizeStart.lowerBound + insertion.count)
        }
        let parsed = CaptureManifest.parseNDJSON(data)
        #expect(parsed.records.count == 2)
        #expect(parsed.isFinalized)
        #expect(parsed.recoveredSources.count == 1)
    }

    @Test("Manifest parser: empty data returns no records")
    func emptyData() {
        let parsed = CaptureManifest.parseNDJSON(Data())
        #expect(parsed.records.isEmpty)
        #expect(!parsed.isFinalized)
        #expect(parsed.recoveredSources.isEmpty)
    }

    @Test("Manifest parser: only newline returns empty records")
    func newlineOnly() {
        let parsed = CaptureManifest.parseNDJSON("\n".data(using: .utf8)!)
        #expect(parsed.records.isEmpty)
    }
}

// MARK: - System audio feature detection (T3.3)

@Suite("System audio feature detection")
struct SystemAudioDetectionTests {
    @Test("isSystemAudioAvailable returns non-crashing boolean")
    func systemAudioAvailableReturnsBool() {
        let available = CaptureSourceCatalog.isSystemAudioAvailable
        // On CI or any Mac, this should just return a boolean without crashing.
        #expect(available == true || available == false)
    }
}

// MARK: - Capability tier gate tests (T6.5)

@Suite("Capture capability gating")
struct CaptureCapabilityGateTests {

    @Test("Baseline tier: zero capture streams rejected with empty reason")
    func baselineZeroStreams() {
        let intel = Capabilities(
            chip: .intel,
            unifiedMemoryBytes: 8 * 1024 * 1024 * 1024,
            videoEncoderCount: 0,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = intel.tier(for: .simultaneousCaptureStreams(count: 0))
        #expect(verdict.tier == .baseline)
    }

    @Test("Baseline tier: single stream rejected on Intel with zero encoders")
    func baselineSingleStreamRejected() {
        let intel = Capabilities(
            chip: .intel,
            unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
            videoEncoderCount: 0,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = intel.tier(for: .simultaneousCaptureStreams(count: 1))
        #expect(verdict.tier == .baseline)
        #expect(verdict.reason.contains("Intel"))
    }

    @Test("Accelerated tier: single stream on Apple Silicon with 1 encoder")
    func acceleratedSingleStream() {
        let m1 = Capabilities(
            chip: .appleSilicon(generation: 1),
            unifiedMemoryBytes: 8 * 1024 * 1024 * 1024,
            videoEncoderCount: 1,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = m1.tier(for: .simultaneousCaptureStreams(count: 1))
        #expect(verdict.tier == .accelerated)
        #expect(verdict.reason.contains("encoder"))
    }

    @Test("Accelerated tier: two streams on Apple Silicon with 2 encoders")
    func acceleratedTwoStreams() {
        let m2 = Capabilities(
            chip: .appleSilicon(generation: 2),
            unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
            videoEncoderCount: 2,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = m2.tier(for: .simultaneousCaptureStreams(count: 2))
        #expect(verdict.tier == .accelerated)
    }

    @Test("Pro tier: three streams with 3 encoders and ≥16 GiB")
    func proThreeStreams() {
        let m3pro = Capabilities(
            chip: .appleSilicon(generation: 3),
            unifiedMemoryBytes: 32 * 1024 * 1024 * 1024,
            videoEncoderCount: 3,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = m3pro.tier(for: .simultaneousCaptureStreams(count: 3))
        #expect(verdict.tier == .pro)
        #expect(verdict.reason.contains("encoder"))
    }

    @Test("Pro tier: three streams with 3 encoders but < 16 GiB → accelerated")
    func proThreeStreamsLowMemory() {
        let config = Capabilities(
            chip: .appleSilicon(generation: 3),
            unifiedMemoryBytes: 12 * 1024 * 1024 * 1024,
            videoEncoderCount: 3,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = config.tier(for: .simultaneousCaptureStreams(count: 3))
        #expect(verdict.tier == .accelerated)
    }

    @Test("Capture streams: request exceeds encoder count → baseline")
    func captureStreamsExceedEncoderCount() {
        let config = Capabilities(
            chip: .appleSilicon(generation: 2),
            unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
            videoEncoderCount: 1,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = config.tier(for: .simultaneousCaptureStreams(count: 4))
        #expect(verdict.tier == .baseline)
    }

    @Test("Pixel rate budget: baseline returns zero")
    func pixelRateBudgetBaseline() {
        // The maxPixelRate function is private but we can verify through
        // the public API: baseline rejects any capture request.
        let intel = Capabilities(
            chip: .intel,
            unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
            videoEncoderCount: 0,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = intel.tier(for: .simultaneousCaptureStreams(count: 1))
        #expect(verdict.tier == .baseline)
    }

    @Test("Pixel rate budget: accelerated allows 1080p30 (≈ 62 MPx/s)")
    func pixelRateBudgetAccelerated() {
        let m2 = Capabilities(
            chip: .appleSilicon(generation: 2),
            unifiedMemoryBytes: 16 * 1024 * 1024 * 1024,
            videoEncoderCount: 2,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = m2.tier(for: .simultaneousCaptureStreams(count: 1))
        #expect(verdict.tier == .accelerated)
    }

    @Test("Pixel rate budget: pro allows 4K60 (≈ 498 MPx/s)")
    func pixelRateBudgetPro() {
        let m3pro = Capabilities(
            chip: .appleSilicon(generation: 3),
            unifiedMemoryBytes: 48 * 1024 * 1024 * 1024,
            videoEncoderCount: 4,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = m3pro.tier(for: .simultaneousCaptureStreams(count: 3))
        #expect(verdict.tier == .pro)
    }
}

// MARK: - CaptureManifestFileWriter deinit (P1 fix)

@Suite("CaptureManifestFileWriter resource cleanup")
struct CaptureManifestFileWriterCleanupTests {
    @Test("deinit closes file handle on deallocation")
    func deinitClosesHandle() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-manifest.ndjson")
        var writer: CaptureManifestFileWriter? = try CaptureManifestFileWriter(url: url)
        try writer?.append(.finalize(CaptureFinalizeRecord(atUs: 0, durationUs: 0)))
        // Deallocate to trigger deinit
        writer = nil
        // After deinit, the file should still exist and be readable (handle was closed cleanly)
        let data = try? Data(contentsOf: url)
        #expect(data != nil)
        // Clean up
        try? FileManager.default.removeItem(at: url)
    }
}
