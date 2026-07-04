import Testing
import Foundation
import CoreVideo
import CoreMedia
@testable import LocalCut_Studio
import LocalCutCore

@Suite("ProgramSession")
struct ProgramSessionTests {

    private nonisolated final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgramSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func testSource(id: UUID = UUID(), kind: CaptureSourceKind = .display) -> CaptureSourceDescriptor {
        CaptureSourceDescriptor(
            id: id,
            kind: kind,
            displayName: "Test",
            relativePath: "\(id.uuidString).mov",
            width: 1920,
            height: 1080,
            frameRate: 30)
    }

    private func testScene(sourceId: UUID) -> SceneDefinition {
        SceneDefinition(name: "Test", layers: [
            SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 0)
        ])
    }

    private func makeTestBuffer(width: Int = 64, height: Int = 64) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer)
        return try #require(pixelBuffer)
    }

    @Test("Starting a second session fails clearly")
    func secondSessionFails() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)
        let source = testSource()
        let scene = testScene(sourceId: source.id)

        // Start first session.
        try await session.start(
            sources: [source],
            scenes: [scene],
            renderSize: CGSize(width: 1920, height: 1080),
            onFrame: { _ in })

        // Second start should fail.
        await #expect(throws: ProgramSessionError.self) {
            try await session.start(
                sources: [source],
                scenes: [scene],
                renderSize: CGSize(width: 1920, height: 1080),
                onFrame: { _ in })
        }

        // Clean up.
        _ = try await session.stop()
    }

    @Test("Start with budget exhaustion opens no encoders")
    func budgetExhaustionOpensNoEncoders() async throws {
        // Budget of 1: the session needs 1 video source, but the budget
        // is already exhausted before start.
        let budget = EncoderBudget(maxConcurrent: 1)
        // Pre-exhaust the budget.
        let preLease = try await budget.acquire(.export)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)
        let source = testSource()
        let scene = testScene(sourceId: source.id)

        await #expect(throws: ProgramSessionError.self) {
            try await session.start(
                sources: [source],
                scenes: [scene],
                renderSize: CGSize(width: 1920, height: 1080),
                onFrame: { _ in })
        }
        #expect(await !session.isRunning)
        await preLease.relinquish(budget: budget)
    }

    @Test("Partial setup failure cleans up leases")
    func partialFailureCleansUp() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)

        // Empty sources should fail.
        await #expect(throws: ProgramSessionError.noSources) {
            try await session.start(
                sources: [],
                scenes: [testScene(sourceId: UUID())],
                renderSize: CGSize(width: 1920, height: 1080),
                onFrame: { _ in })
        }
        #expect(await !session.isRunning)
    }

    @Test("Stop closes writers/taps/compositor once")
    func stopClosesCleanly() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)
        let source = testSource()
        let scene = testScene(sourceId: source.id)

        try await session.start(
            sources: [source],
            scenes: [scene],
            renderSize: CGSize(width: 1920, height: 1080),
            onFrame: { _ in })

        let result = try await session.stop()
        #expect(result.sessionID != UUID())
        #expect(result.duration.isValid)
        #expect(await !session.isRunning)
    }

    @Test("Scene switch records manifest event")
    func sceneSwitchRecordsEvent() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)
        let source = testSource()
        let sceneA = SceneDefinition(name: "A", layers: [
            SceneLayer(sourceRef: .captureSource(source.id), zIndex: 0)
        ])
        let sceneB = SceneDefinition(name: "B", layers: [
            SceneLayer(sourceRef: .captureSource(source.id), zIndex: 1)
        ])

        try await session.start(
            sources: [source],
            scenes: [sceneA, sceneB],
            renderSize: CGSize(width: 1920, height: 1080),
            onFrame: { _ in })

        await session.switchScene(to: sceneB.id)

        let result = try await session.stop()
        // Verify scene-switch records are in the manifest.
        let switches = result.manifest.sceneSwitchRecords
        #expect(switches.count == 2)
        #expect(switches[0].sceneId == sceneA.id)
        #expect(switches[1].sceneId == sceneB.id)
    }

    @Test("Feeding a video frame emits a program frame")
    func feedFrameEmitsProgramFrame() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)
        let source = testSource()
        let scene = testScene(sourceId: source.id)
        let counter = FrameCounter()

        try await session.start(
            sources: [source],
            scenes: [scene],
            renderSize: CGSize(width: 64, height: 64),
            onFrame: { _ in counter.increment() })

        await session.feedFrame(sourceID: source.id, buffer: ProgramFrameBuffer(try makeTestBuffer()))

        #expect(counter.value == 1)
        _ = try await session.stop()
    }

    @Test("Dynamic frame sinks can be added and removed while running")
    func dynamicFrameSinkCanBeRemoved() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)
        let source = testSource()
        let scene = testScene(sourceId: source.id)
        let counter = FrameCounter()

        try await session.start(
            sources: [source],
            scenes: [scene],
            renderSize: CGSize(width: 64, height: 64))

        let sinkID = await session.addFrameSink { _ in counter.increment() }
        await session.feedFrame(sourceID: source.id, buffer: ProgramFrameBuffer(try makeTestBuffer()))
        #expect(counter.value == 1)

        await session.removeFrameSink(id: sinkID)
        await session.feedFrame(sourceID: source.id, buffer: ProgramFrameBuffer(try makeTestBuffer()))
        #expect(counter.value == 1)

        _ = try await session.stop()
    }

    @Test("Source list supports screen, camera, and mic inputs")
    func sourceListSupportsMultipleTypes() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)

        let screen = testSource(kind: .display)
        let camera = testSource(kind: .webcam)
        let mic = testSource(kind: .microphone)
        let sources = [screen, camera, mic]

        let scene = SceneDefinition(name: "All", layers: [
            SceneLayer(sourceRef: .captureSource(screen.id), zIndex: 0),
            SceneLayer(sourceRef: .captureSource(camera.id), zIndex: 1),
        ])

        try await session.start(
            sources: sources,
            scenes: [scene],
            renderSize: CGSize(width: 1920, height: 1080),
            onFrame: { _ in })

        let result = try await session.stop()
        // Should have header with all 3 sources.
        #expect(result.manifest.header?.sources.count == 3)
    }

    @Test("No sources throws error")
    func noSourcesThrows() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)

        await #expect(throws: ProgramSessionError.noSources) {
            try await session.start(
                sources: [],
                scenes: [testScene(sourceId: UUID())],
                renderSize: CGSize(width: 1920, height: 1080),
                onFrame: { _ in })
        }
    }

    @Test("No scenes throws error")
    func noScenesThrows() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)

        await #expect(throws: ProgramSessionError.noScenes) {
            try await session.start(
                sources: [testSource()],
                scenes: [],
                renderSize: CGSize(width: 1920, height: 1080),
                onFrame: { _ in })
        }
    }

    @Test("Hotkey conflict throws error")
    func hotkeyConflictThrows() async throws {
        let budget = EncoderBudget(maxConcurrent: 4)
        let dir = try tempDir()
        let session = ProgramSession(budget: budget, rootURL: dir)
        let sourceId = UUID()
        let scenes = [
            SceneDefinition(name: "A", hotkey: "1", layers: [
                SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 0)
            ]),
            SceneDefinition(name: "B", hotkey: "1", layers: [
                SceneLayer(sourceRef: .captureSource(sourceId), zIndex: 1)
            ]),
        ]

        await #expect(throws: ProgramSessionError.self) {
            try await session.start(
                sources: [testSource(id: sourceId)],
                scenes: scenes,
                renderSize: CGSize(width: 1920, height: 1080),
                onFrame: { _ in })
        }
    }
}
