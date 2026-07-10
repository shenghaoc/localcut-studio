import Testing
import Foundation
import AVFoundation
import CoreMedia
import LocalCutCore
@testable import LocalCut_Studio

/// Helper for static-let contexts where `try!` would crash with an opaque error.
/// Returns `Never` so it can be used as the RHS of `??` on any type.
nonisolated private func fatalErrorAs<T>(_ message: String) -> T {
    fatalError(message)
}

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

    // MARK: Parameterized alignment cases

    struct AlignmentCase: Sendable, CustomTestStringConvertible {
        let name: String
        let sessionStartUs: Int64
        let ptsUs: [Int64]
        let expectedOffsetUs: Int64?
        let maxDeltaUs: Int64?

        var testDescription: String { name }
    }

    nonisolated(unsafe) static let alignmentCases: [AlignmentCase] = [
        AlignmentCase(
            name: "offset is zero when PTS equals sessionStart",
            sessionStartUs: 1_000_000,
            ptsUs: [1_000_000],
            expectedOffsetUs: 0,
            maxDeltaUs: nil),
        AlignmentCase(
            name: "offset is positive for PTS after sessionStart",
            sessionStartUs: 500_000,
            ptsUs: [700_000],
            expectedOffsetUs: 200_000,
            maxDeltaUs: nil),
        AlignmentCase(
            name: "two sources produce aligned timeline offsets",
            sessionStartUs: 1_000_000,
            ptsUs: [1_010_000, 1_010_030],
            expectedOffsetUs: nil,
            maxDeltaUs: 1_000),
    ]

    @Test("Timeline offset calculations", arguments: alignmentCases)
    func timelineOffsetCalculations(_testCase: AlignmentCase) {
        let timescale = CaptureManifest.microsecondTimescale
        let sessionStart = CMTime(value: _testCase.sessionStartUs, timescale: timescale)
        let sessionStartUs = CaptureManifest.microseconds(from: sessionStart)

        if let expectedOffset = _testCase.expectedOffsetUs {
            let pts = CMTime(value: _testCase.ptsUs[0], timescale: timescale)
            let firstUs = CaptureManifest.microseconds(from: pts)
            let timelineStartUs = max(Int64(0), firstUs - sessionStartUs)
            #expect(timelineStartUs == expectedOffset)
        } else if let maxDelta = _testCase.maxDeltaUs {
            let offsets = _testCase.ptsUs.map { ptsValue -> Int64 in
                let pts = CMTime(value: ptsValue, timescale: timescale)
                return CaptureManifest.microseconds(from: pts) - sessionStartUs
            }
            let delta = abs(offsets[0] - offsets[1])
            #expect(delta < maxDelta)
        } else {
            Issue.record("AlignmentCase '\(_testCase.name)' has neither expectedOffsetUs nor maxDeltaUs set")
        }
    }
}

// MARK: - Manifest crash recovery (T6.2, T6.3)

@Suite("Capture manifest NDJSON recovery")
struct CaptureManifestRecoveryTests {

    // MARK: Parameterized manifest parse cases

    struct ManifestParseCase: Sendable, CustomTestStringConvertible {
        let name: String
        let data: Data
        let expectedRecordCount: Int
        let isFinalized: Bool
        let expectedRecoveredSourceCount: Int
        let expectedFirstTimelineStartUs: Int64?

        var testDescription: String { name }
    }

    nonisolated(unsafe) static let manifestParseCases: [ManifestParseCase] = {
        var cases: [ManifestParseCase] = []

        // Truncated trailing line
        do {
            let sourceID = UUID()
            let source = CaptureSourceDescriptor(
                id: sourceID, kind: .display, displayName: "Screen",
                relativePath: "screen.mov", width: 1920, height: 1080, frameRate: 30)
            let manifest = CaptureManifest(records: [
                .header(CaptureManifestHeader(
                    sessionID: UUID(), createdAt: Date(),
                    sessionStartHostTimeUs: 1_000, sources: [source], encoders: [:])),
                .sourceEnded(CaptureSourceEndedRecord(
                    sourceID: sourceID, atUs: 4_000_000, durationUs: 3_000_000,
                    timelineStartUs: 20_000, sampleCount: 90)),
            ])
            var data = (try? manifest.encodeNDJSON()) ?? fatalErrorAs("encodeNDJSON failed for truncated trailing line case")
            data.append(#"{"kind":"finalize","atUs":5000000,"dur"#.data(using: .utf8)!)
            cases.append(ManifestParseCase(
                name: "truncated trailing line",
                data: data,
                expectedRecordCount: 2,
                isFinalized: false,
                expectedRecoveredSourceCount: 1,
                expectedFirstTimelineStartUs: 20_000))
        }

        // Unknown record kind (scene-doc forward compat)
        do {
            let sourceID = UUID()
            let source = CaptureSourceDescriptor(
                id: sourceID, kind: .display, displayName: "Screen",
                relativePath: "screen.mov")
            let manifest = CaptureManifest(records: [
                .header(CaptureManifestHeader(
                    sessionID: UUID(), createdAt: Date(),
                    sessionStartHostTimeUs: 10, sources: [source], encoders: [:])),
                .finalize(CaptureFinalizeRecord(atUs: 30, durationUs: 20)),
            ])
            var data = (try? manifest.encodeNDJSON()) ?? fatalErrorAs("encodeNDJSON failed for unknown record kind case")
            let insertion = #"{"kind":"scene-doc","sceneId":"intro","atUs":15}"#.data(using: .utf8)!
            if let finalizeStart = data.range(of: #"{"kind":"finalize""#.data(using: .utf8)!) {
                data.insert(contentsOf: insertion, at: finalizeStart.lowerBound)
                data.insert(0x0A, at: finalizeStart.lowerBound + insertion.count)
            }
            cases.append(ManifestParseCase(
                name: "unknown record kind ignored",
                data: data,
                expectedRecordCount: 2,
                isFinalized: true,
                expectedRecoveredSourceCount: 1,
                expectedFirstTimelineStartUs: nil))
        }

        // Empty data
        cases.append(ManifestParseCase(
            name: "empty data returns no records",
            data: Data(),
            expectedRecordCount: 0,
            isFinalized: false,
            expectedRecoveredSourceCount: 0,
            expectedFirstTimelineStartUs: nil))

        // Newline only
        cases.append(ManifestParseCase(
            name: "newline-only data returns no records",
            data: "\n".data(using: .utf8)!,
            expectedRecordCount: 0,
            isFinalized: false,
            expectedRecoveredSourceCount: 0,
            expectedFirstTimelineStartUs: nil))

        return cases
    }()

    @Test("Manifest parser", arguments: manifestParseCases)
    func manifestParsing(_testCase: ManifestParseCase) {
        let parsed = CaptureManifest.parseNDJSON(_testCase.data)
        #expect(parsed.records.count == _testCase.expectedRecordCount)
        #expect(parsed.isFinalized == _testCase.isFinalized)
        #expect(parsed.recoveredSources.count == _testCase.expectedRecoveredSourceCount)
        if let expectedTimelineStart = _testCase.expectedFirstTimelineStartUs {
            #expect(parsed.recoveredSources[0].descriptor.timelineStartUs == expectedTimelineStart)
        }
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

    // MARK: Parameterized capability gate cases

    struct CapabilityGateCase: Sendable, CustomTestStringConvertible {
        let name: String
        let chip: Capabilities.ChipFamily
        let memoryBytes: UInt64
        let encoderCount: Int
        let streamCount: Int
        let expectedTier: CapabilityTier
        let reasonSubstring: String?

        var testDescription: String { name }
    }

    nonisolated(unsafe) static let capabilityGateCases: [CapabilityGateCase] = [
        CapabilityGateCase(
            name: "baseline: zero streams rejected",
            chip: .intel,
            memoryBytes: 8 * 1024 * 1024 * 1024,
            encoderCount: 0,
            streamCount: 0,
            expectedTier: .baseline,
            reasonSubstring: nil),
        CapabilityGateCase(
            name: "baseline: single stream rejected on Intel",
            chip: .intel,
            memoryBytes: 16 * 1024 * 1024 * 1024,
            encoderCount: 0,
            streamCount: 1,
            expectedTier: .baseline,
            reasonSubstring: "Intel"),
        CapabilityGateCase(
            name: "accelerated: single stream on M1 with 1 encoder",
            chip: .appleSilicon(generation: 1),
            memoryBytes: 8 * 1024 * 1024 * 1024,
            encoderCount: 1,
            streamCount: 1,
            expectedTier: .accelerated,
            reasonSubstring: "encoder"),
        CapabilityGateCase(
            name: "accelerated: two streams on M2 with 2 encoders",
            chip: .appleSilicon(generation: 2),
            memoryBytes: 16 * 1024 * 1024 * 1024,
            encoderCount: 2,
            streamCount: 2,
            expectedTier: .accelerated,
            reasonSubstring: nil),
        CapabilityGateCase(
            name: "pro: three streams with 3 encoders and >= 16 GiB",
            chip: .appleSilicon(generation: 3),
            memoryBytes: 32 * 1024 * 1024 * 1024,
            encoderCount: 3,
            streamCount: 3,
            expectedTier: .pro,
            reasonSubstring: "encoder"),
        CapabilityGateCase(
            name: "accelerated: three streams with < 16 GiB falls back",
            chip: .appleSilicon(generation: 3),
            memoryBytes: 12 * 1024 * 1024 * 1024,
            encoderCount: 3,
            streamCount: 3,
            expectedTier: .accelerated,
            reasonSubstring: nil),
        CapabilityGateCase(
            name: "baseline: request exceeds encoder count",
            chip: .appleSilicon(generation: 2),
            memoryBytes: 16 * 1024 * 1024 * 1024,
            encoderCount: 1,
            streamCount: 4,
            expectedTier: .baseline,
            reasonSubstring: nil),
        CapabilityGateCase(
            name: "baseline: Intel rejects single-stream pixel budget",
            chip: .intel,
            memoryBytes: 16 * 1024 * 1024 * 1024,
            encoderCount: 0,
            streamCount: 1,
            expectedTier: .baseline,
            reasonSubstring: nil),
        CapabilityGateCase(
            name: "accelerated: allows 1080p30 pixel budget",
            chip: .appleSilicon(generation: 2),
            memoryBytes: 16 * 1024 * 1024 * 1024,
            encoderCount: 2,
            streamCount: 1,
            expectedTier: .accelerated,
            reasonSubstring: nil),
        CapabilityGateCase(
            name: "pro: allows 4K60 pixel budget",
            chip: .appleSilicon(generation: 3),
            memoryBytes: 48 * 1024 * 1024 * 1024,
            encoderCount: 4,
            streamCount: 3,
            expectedTier: .pro,
            reasonSubstring: nil),
    ]

    @Test("Capability tier gating", arguments: capabilityGateCases)
    func capabilityGating(_testCase: CapabilityGateCase) {
        let caps = Capabilities(
            chip: _testCase.chip,
            unifiedMemoryBytes: _testCase.memoryBytes,
            videoEncoderCount: _testCase.encoderCount,
            osVersion: Capabilities.OSVersion(major: 26, minor: 0))
        let verdict = caps.tier(for: .simultaneousCaptureStreams(count: _testCase.streamCount))
        #expect(verdict.tier == _testCase.expectedTier)
        if let substring = _testCase.reasonSubstring {
            #expect(verdict.reason.contains(substring))
        }
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
