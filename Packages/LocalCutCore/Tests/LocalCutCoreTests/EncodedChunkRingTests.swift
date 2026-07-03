import Testing
import CoreMedia
@testable import LocalCutCore

@Suite("EncodedChunkRing actor")
struct EncodedChunkRingTests {

    private func makeChunk(seconds: Double,
                           duration: Double = 1.0,
                           size: Int = 1024,
                           isKeyframe: Bool = false) -> EncodedChunk {
        EncodedChunk(
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600),
            byteSize: size,
            isKeyframe: isKeyframe,
            sourceID: UUID(),
            data: Data(repeating: 0xAB, count: size))
    }

    @Test("Append and count")
    func appendAndCount() async {
        let ring = EncodedChunkRing(config: .default)
        await ring.append(makeChunk(seconds: 0, isKeyframe: true))
        await ring.append(makeChunk(seconds: 1))
        await ring.append(makeChunk(seconds: 2))

        let count = await ring.chunkCount
        #expect(count == 3)
        let empty = await ring.isEmpty
        #expect(empty == false)
    }

    @Test("Memory accounting")
    func memoryAccounting() async {
        let config = ReplayBufferConfig(memoryBudgetBytes: 10_000, maxDurationSeconds: 60)
        let ring = EncodedChunkRing(config: config)

        await ring.append(makeChunk(seconds: 0, size: 3000, isKeyframe: true))
        await ring.append(makeChunk(seconds: 1, size: 3000))
        await ring.append(makeChunk(seconds: 2, size: 3000))

        let diag = await ring.diagnostics()
        #expect(diag.memoryUsedBytes == 9000)
        #expect(diag.inMemoryChunkCount == 3)
    }

    @Test("Duration cap evicts oldest chunks")
    func durationCap() async {
        let config = ReplayBufferConfig(memoryBudgetBytes: 1_000_000, maxDurationSeconds: 5)
        let ring = EncodedChunkRing(config: config)

        // Add chunks spanning 10 seconds.
        for i in 0..<10 {
            await ring.append(makeChunk(seconds: Double(i), duration: 1.0, isKeyframe: i % 3 == 0))
        }

        let count = await ring.chunkCount
        // Should have evicted chunks older than 5 seconds from the end.
        #expect(count < 10)
        let diag = await ring.diagnostics()
        #expect(diag.bufferedDurationSeconds <= 5.0 + 1.0) // +1 for the last chunk's duration
    }

    @Test("Budget enforcement drops oldest keyframe-aligned spans")
    func budgetEnforcement() async {
        let config = ReplayBufferConfig(memoryBudgetBytes: 5000, maxDurationSeconds: 60)
        let ring = EncodedChunkRing(config: config)

        // Add chunks until budget is exceeded.
        for i in 0..<10 {
            await ring.append(makeChunk(seconds: Double(i), size: 1024, isKeyframe: i % 3 == 0))
        }

        let diag = await ring.diagnostics()
        #expect(diag.memoryUsedBytes <= 5000)
    }

    @Test("Diagnostics snapshot")
    func diagnosticsSnapshot() async {
        let config = ReplayBufferConfig(memoryBudgetBytes: 1024 * 1024, maxDurationSeconds: 30)
        let ring = EncodedChunkRing(config: config)

        await ring.append(makeChunk(seconds: 0, size: 512, isKeyframe: true))
        await ring.append(makeChunk(seconds: 1, size: 512))

        let diag = await ring.diagnostics()
        #expect(diag.memoryUsedBytes == 1024)
        #expect(diag.memoryBudgetBytes == 1024 * 1024)
        #expect(diag.inMemoryChunkCount == 2)
        #expect(diag.spilledChunkCount == 0)
        #expect(diag.bufferedDurationSeconds > 0)
        #expect(diag.maxDurationSeconds == 30)
    }

    @Test("Select save span finds latest keyframe at or before boundary")
    func selectSaveSpan() async {
        let ring = EncodedChunkRing(config: .default)

        // Keyframes at 0s, 3s, 6s, 9s
        await ring.append(makeChunk(seconds: 0, duration: 1, isKeyframe: true))
        await ring.append(makeChunk(seconds: 1, duration: 1))
        await ring.append(makeChunk(seconds: 2, duration: 1))
        await ring.append(makeChunk(seconds: 3, duration: 1, isKeyframe: true))
        await ring.append(makeChunk(seconds: 4, duration: 1))
        await ring.append(makeChunk(seconds: 5, duration: 1))
        await ring.append(makeChunk(seconds: 6, duration: 1, isKeyframe: true))
        await ring.append(makeChunk(seconds: 7, duration: 1))
        await ring.append(makeChunk(seconds: 8, duration: 1))
        await ring.append(makeChunk(seconds: 9, duration: 1, isKeyframe: true))

        // Save last 5 seconds. End is at 10s, boundary is 5s. Latest
        // keyframe at or before 5s is at 3s.
        let now = CMTime(seconds: 10, preferredTimescale: 600)
        let (selected, actualSeconds) = await ring.selectSaveSpan(seconds: 5, now: now)

        #expect(!selected.isEmpty)
        #expect(selected.first?.isKeyframe == true)
        // Should start at 3s (the latest keyframe at or before 5s).
        #expect(selected.first?.presentationTimeStamp.seconds == 3.0)
        #expect(actualSeconds >= 5.0)
    }

    @Test("Short session returns available span from earliest keyframe")
    func shortSessionSave() async {
        let ring = EncodedChunkRing(config: .default)

        await ring.append(makeChunk(seconds: 0, duration: 1, isKeyframe: true))
        await ring.append(makeChunk(seconds: 1, duration: 1))

        let (selected, actual) = await ring.selectSaveSpan(seconds: 30, now: CMTime(seconds: 2, preferredTimescale: 600))

        #expect(selected.count == 2)
        #expect(actual > 0)
    }

    @Test("Ring starts at keyframe after eviction")
    func ringStartsAtKeyframe() async {
        let config = ReplayBufferConfig(memoryBudgetBytes: 3000, maxDurationSeconds: 60)
        let ring = EncodedChunkRing(config: config)

        // Non-keyframe first, then keyframe, then more.
        await ring.append(makeChunk(seconds: 0, size: 1000, isKeyframe: false))
        await ring.append(makeChunk(seconds: 1, size: 1000, isKeyframe: true))
        await ring.append(makeChunk(seconds: 2, size: 1000, isKeyframe: false))
        await ring.append(makeChunk(seconds: 3, size: 1000, isKeyframe: true))

        let all = await ring.allChunks
        if let first = all.first {
            #expect(first.isKeyframe == true)
        }
    }

    @Test("Clear empties the ring")
    func clearEmpties() async {
        let ring = EncodedChunkRing(config: .default)
        await ring.append(makeChunk(seconds: 0, isKeyframe: true))
        await ring.append(makeChunk(seconds: 1))

        await ring.clear()
        let count = await ring.chunkCount
        #expect(count == 0)
        let diag = await ring.diagnostics()
        #expect(diag.memoryUsedBytes == 0)
    }

    @Test("Update config triggers re-eviction")
    func updateConfigTriggersEviction() async {
        let config = ReplayBufferConfig(memoryBudgetBytes: 100_000, maxDurationSeconds: 60)
        let ring = EncodedChunkRing(config: config)

        for i in 0..<20 {
            await ring.append(makeChunk(seconds: Double(i), duration: 1, size: 1000, isKeyframe: i % 3 == 0))
        }

        let countBefore = await ring.chunkCount
        #expect(countBefore == 20)

        // Tighten duration to 5 seconds.
        let tightConfig = ReplayBufferConfig(memoryBudgetBytes: 100_000, maxDurationSeconds: 5)
        await ring.updateConfig(tightConfig)

        let countAfter = await ring.chunkCount
        #expect(countAfter < countBefore)
    }

    @Test("Spill path is under Caches directory")
    func spillPathUnderCaches() async {
        let ring = EncodedChunkRing(config: .default)
        let url = await ring.spillDirectoryURL
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #expect(url.path.hasPrefix(caches.path))
        #expect(url.path.contains("ReplayBuffer"))
    }

    @Test("Spill directory can be prepared without error")
    func spillDirectoryPreparation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayBufferTest-\(UUID().uuidString)")
        let ring = EncodedChunkRing(
            config: ReplayBufferConfig(memoryBudgetBytes: 2000, maxDurationSeconds: 60),
            spillDirectory: tempDir)

        try await ring.prepareSpillDirectory()
        #expect(FileManager.default.fileExists(atPath: tempDir.path))

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Spilled chunks can be read back via unified index")
    func spilledChunksReadable() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayBufferTest-\(UUID().uuidString)")
        let config = ReplayBufferConfig(memoryBudgetBytes: 2000, maxDurationSeconds: 60)
        let ring = EncodedChunkRing(config: config, spillDirectory: tempDir)

        try await ring.prepareSpillDirectory()

        // Add chunks that exceed memory budget to trigger spilling.
        for i in 0..<6 {
            let chunk = makeChunk(seconds: Double(i), size: 1024, isKeyframe: i % 2 == 0)
            await ring.appendWithSpill(chunk)
        }

        let diag = await ring.diagnostics()
        #expect(diag.spilledChunkCount > 0)

        // Load a spilled chunk back.
        let all = await ring.allChunks
        if let spilled = all.first(where: { $0.isSpilled }) {
            let loaded = await ring.loadSpilledChunk(id: spilled.id)
            #expect(loaded != nil)
            #expect(loaded?.data != nil)
            #expect(loaded?.data?.count == spilled.byteSize)
        }

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Save span works across memory and spill boundary")
    func saveSpanAcrossSpillBoundary() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayBufferTest-\(UUID().uuidString)")
        let config = ReplayBufferConfig(memoryBudgetBytes: 3000, maxDurationSeconds: 60)
        let ring = EncodedChunkRing(config: config, spillDirectory: tempDir)

        try await ring.prepareSpillDirectory()

        // Add many chunks so some get spilled.
        for i in 0..<10 {
            let chunk = makeChunk(seconds: Double(i), size: 1024, isKeyframe: i % 3 == 0)
            await ring.appendWithSpill(chunk)
        }

        let (span, _) = await ring.selectSaveSpan(seconds: 5, now: CMTime(seconds: 10, preferredTimescale: 600))
        #expect(!span.isEmpty)
        #expect(span.first?.isKeyframe == true)

        // Load all chunks for save.
        let loaded = await ring.loadChunksForSave(span)
        #expect(loaded.count == span.count)
        for chunk in loaded {
            #expect(chunk.data != nil)
        }

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Clear removes spill files")
    func clearRemovesSpillFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayBufferTest-\(UUID().uuidString)")
        let config = ReplayBufferConfig(memoryBudgetBytes: 2000, maxDurationSeconds: 60)
        let ring = EncodedChunkRing(config: config, spillDirectory: tempDir)

        try await ring.prepareSpillDirectory()

        for i in 0..<6 {
            await ring.appendWithSpill(makeChunk(seconds: Double(i), size: 1024, isKeyframe: i % 2 == 0))
        }

        await ring.clear()
        #expect(!FileManager.default.fileExists(atPath: tempDir.path))
    }
}
