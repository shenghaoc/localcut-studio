import Testing
import CoreMedia
import Foundation
@testable import LocalCutCore

@Suite("EncodedChunkRing actor")
struct EncodedChunkRingTests {

    private func makeChunk(seconds: Double,
                           duration: Double = 1.0,
                           size: Int = 1024,
                           isKeyframe: Bool = false,
                           mediaType: EncodedChunkMediaType = .video,
                           sourceFile: URL? = nil) -> EncodedChunk {
        EncodedChunk(
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            sourceTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600),
            byteSize: size,
            isKeyframe: isKeyframe,
            mediaType: mediaType,
            sourceID: UUID(),
            sourceFileURL: sourceFile ?? URL(fileURLWithPath: "/tmp/test.mov"))
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

    @Test("Duration cap evicts oldest chunks")
    func durationCap() async {
        let config = ReplayBufferConfig(maxDurationSeconds: 5)
        let ring = EncodedChunkRing(config: config)

        // Add chunks spanning 10 seconds.
        for i in 0..<10 {
            await ring.append(makeChunk(seconds: Double(i), duration: 1.0, isKeyframe: i % 3 == 0))
        }

        let count = await ring.chunkCount
        // Should have evicted chunks older than 5 seconds from the end.
        #expect(count < 10)
        let diag = await ring.diagnostics()
        // Duration eviction keeps from a keyframe boundary, so the window may
        // exceed the nominal cap by up to one GOP.
        #expect(diag.bufferedDurationSeconds <= 8.0)
    }

    @Test("Diagnostics snapshot")
    func diagnosticsSnapshot() async {
        let config = ReplayBufferConfig(maxDurationSeconds: 30)
        let ring = EncodedChunkRing(config: config)

        await ring.append(makeChunk(seconds: 0, size: 512, isKeyframe: true))
        await ring.append(makeChunk(seconds: 1, size: 512))

        let diag = await ring.diagnostics()
        #expect(diag.chunkCount == 2)
        #expect(diag.bufferedDurationSeconds > 0)
        #expect(diag.maxDurationSeconds == 30)
        #expect(diag.sourceCount == 1)
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
        let config = ReplayBufferConfig(maxDurationSeconds: 3)
        let ring = EncodedChunkRing(config: config)

        // Non-keyframe first, then keyframe, then more.
        await ring.append(makeChunk(seconds: 0, isKeyframe: false))
        await ring.append(makeChunk(seconds: 1, isKeyframe: true))
        await ring.append(makeChunk(seconds: 2, isKeyframe: false))
        await ring.append(makeChunk(seconds: 3, isKeyframe: true))
        await ring.append(makeChunk(seconds: 4, isKeyframe: false))
        await ring.append(makeChunk(seconds: 5, isKeyframe: true))

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
    }

    @Test("Update config triggers re-eviction")
    func updateConfigTriggersEviction() async {
        let config = ReplayBufferConfig(maxDurationSeconds: 60)
        let ring = EncodedChunkRing(config: config)

        for i in 0..<20 {
            await ring.append(makeChunk(seconds: Double(i), duration: 1, isKeyframe: i % 3 == 0))
        }

        let countBefore = await ring.chunkCount
        #expect(countBefore == 20)

        // Tighten duration to 5 seconds.
        let tightConfig = ReplayBufferConfig(maxDurationSeconds: 5)
        await ring.updateConfig(tightConfig)

        let countAfter = await ring.chunkCount
        #expect(countAfter < countBefore)
    }

    @Test("Source file URLs are tracked")
    func sourceFileURLs() async {
        let ring = EncodedChunkRing(config: .default)
        let url1 = URL(fileURLWithPath: "/tmp/screen.mov")
        let url2 = URL(fileURLWithPath: "/tmp/webcam.mov")

        await ring.append(makeChunk(seconds: 0, isKeyframe: true, sourceFile: url1))
        await ring.append(makeChunk(seconds: 1, sourceFile: url2))

        let sources = await ring.sourceFileURLs
        #expect(sources.count == 2)
        #expect(sources.contains(url1))
        #expect(sources.contains(url2))
    }

    @Test("Select save span includes audio overlapping video keyframe")
    func selectSaveSpanIncludesAudio() async {
        let ring = EncodedChunkRing(config: .default)
        let videoURL = URL(fileURLWithPath: "/tmp/screen.mov")
        let audioURL = URL(fileURLWithPath: "/tmp/microphone.mov")

        await ring.append(makeChunk(seconds: 0, isKeyframe: true, mediaType: .video, sourceFile: videoURL))
        await ring.append(makeChunk(seconds: 0.2, duration: 0.5, isKeyframe: true, mediaType: .audio, sourceFile: audioURL))
        await ring.append(makeChunk(seconds: 1, isKeyframe: false, mediaType: .video, sourceFile: videoURL))

        let (selected, _) = await ring.selectSaveSpan(seconds: 1, now: CMTime(seconds: 1.5, preferredTimescale: 600))

        #expect(selected.contains { $0.mediaType == .video })
        #expect(selected.contains { $0.mediaType == .audio })
    }

    @Test("Memory budget spills oldest keyframe-aligned resident segment")
    func memoryBudgetSpillsOldestSegment() async throws {
        let spillDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("encoded-ring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: spillDirectory) }

        let config = ReplayBufferConfig(maxDurationSeconds: 30, maxMemoryBytes: 1_500)
        let ring = EncodedChunkRing(config: config, spillDirectory: spillDirectory)

        await ring.append(makeChunk(seconds: 0, size: 1_000, isKeyframe: true))
        await ring.append(makeChunk(seconds: 1, size: 1_000, isKeyframe: false))
        await ring.append(makeChunk(seconds: 2, size: 1_000, isKeyframe: true))

        let diag = await ring.diagnostics()
        #expect(diag.residentMemoryBytes <= config.maxMemoryBytes)
        #expect(diag.spilledChunkCount >= 2)
        #expect(diag.spillBytes > 0)

        let files = try FileManager.default.contentsOfDirectory(
            at: spillDirectory,
            includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)

        await ring.clear()

        let clearedDiag = await ring.diagnostics()
        #expect(clearedDiag.chunkCount == 0)
        #expect(clearedDiag.spillBytes == 0)

        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: spillDirectory,
            includingPropertiesForKeys: nil)
        #expect(remainingFiles.isEmpty)
    }
}
