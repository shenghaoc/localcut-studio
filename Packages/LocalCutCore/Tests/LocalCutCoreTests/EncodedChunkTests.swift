import Testing
import CoreMedia
@testable import LocalCutCore

@Suite("Encoded chunk model")
struct EncodedChunkTests {

    @Test("Chunk metadata round-trips correctly")
    func chunkMetadata() {
        let pts = CMTime(seconds: 1.5, preferredTimescale: 600)
        let dur = CMTime(seconds: 2.0, preferredTimescale: 600)
        let sourceID = UUID()
        let data = Data(repeating: 0xAB, count: 1024)

        let chunk = EncodedChunk(
            presentationTimeStamp: pts,
            duration: dur,
            byteSize: 1024,
            isKeyframe: true,
            sourceID: sourceID,
            data: data)

        #expect(chunk.presentationTimeStamp == pts)
        #expect(chunk.duration == dur)
        #expect(chunk.byteSize == 1024)
        #expect(chunk.isKeyframe == true)
        #expect(chunk.sourceID == sourceID)
        #expect(chunk.data?.count == 1024)
        #expect(chunk.isInMemory == true)
        #expect(chunk.isSpilled == false)
        #expect(chunk.memoryBytes == 1024)
    }

    @Test("DTS defaults to PTS when not specified")
    func dtsDefaultsToPTS() {
        let pts = CMTime(seconds: 2.0, preferredTimescale: 600)
        let chunk = EncodedChunk(
            presentationTimeStamp: pts,
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            byteSize: 512,
            isKeyframe: false,
            sourceID: UUID(),
            data: Data())

        #expect(chunk.decodeTimeStamp == pts)
    }

    @Test("End time is PTS + duration")
    func endTime() {
        let pts = CMTime(seconds: 1.0, preferredTimescale: 600)
        let dur = CMTime(seconds: 2.5, preferredTimescale: 600)
        let chunk = EncodedChunk(
            presentationTimeStamp: pts,
            duration: dur,
            byteSize: 100,
            isKeyframe: true,
            sourceID: UUID(),
            data: Data())

        let expected = CMTime(seconds: 3.5, preferredTimescale: 600)
        #expect(chunk.endTime == expected)
    }

    @Test("Byte size accounting")
    func byteSizeAccounting() {
        let chunk = EncodedChunk(
            presentationTimeStamp: .zero,
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            byteSize: 4096,
            isKeyframe: true,
            sourceID: UUID(),
            data: Data(repeating: 0, count: 4096))

        #expect(chunk.byteSize == 4096)
        #expect(chunk.memoryBytes == 4096)
    }

    @Test("Chunk without data has zero memory bytes")
    func noDataMemoryBytes() {
        var chunk = EncodedChunk(
            presentationTimeStamp: .zero,
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            byteSize: 4096,
            isKeyframe: true,
            sourceID: UUID(),
            data: Data(repeating: 0, count: 4096))

        chunk.clearMemoryData()
        #expect(chunk.isInMemory == false)
        #expect(chunk.memoryBytes == 0)
        #expect(chunk.byteSize == 4096) // byteSize is preserved
    }

    @Test("Keyframe flag is preserved")
    func keyframeFlag() {
        let kf = EncodedChunk(
            presentationTimeStamp: .zero,
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            byteSize: 100,
            isKeyframe: true,
            sourceID: UUID(),
            data: Data())
        let nonKf = EncodedChunk(
            presentationTimeStamp: .zero,
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            byteSize: 100,
            isKeyframe: false,
            sourceID: UUID(),
            data: Data())

        #expect(kf.isKeyframe == true)
        #expect(nonKf.isKeyframe == false)
    }

    @Test("Timestamp ordering")
    func timestampOrdering() {
        let t0 = CMTime(seconds: 0, preferredTimescale: 600)
        let t1 = CMTime(seconds: 1, preferredTimescale: 600)
        let t2 = CMTime(seconds: 2, preferredTimescale: 600)

        let c0 = EncodedChunk(presentationTimeStamp: t0, duration: t1, byteSize: 100, isKeyframe: true, sourceID: UUID(), data: Data())
        let c1 = EncodedChunk(presentationTimeStamp: t1, duration: t1, byteSize: 100, isKeyframe: false, sourceID: UUID(), data: Data())
        let c2 = EncodedChunk(presentationTimeStamp: t2, duration: t1, byteSize: 100, isKeyframe: false, sourceID: UUID(), data: Data())

        let chunks = [c2, c0, c1].sorted { $0.presentationTimeStamp < $1.presentationTimeStamp }
        #expect(chunks[0].presentationTimeStamp == t0)
        #expect(chunks[1].presentationTimeStamp == t1)
        #expect(chunks[2].presentationTimeStamp == t2)
    }
}
