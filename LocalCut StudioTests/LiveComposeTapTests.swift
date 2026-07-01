import Testing
import Foundation
import CoreVideo
@testable import LocalCut_Studio

@Suite("LiveComposeTap")
@MainActor
struct LiveComposeTapTests {

    /// Creates a minimal CVPixelBuffer for testing.
    private func makeTestBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer)
        return pixelBuffer
    }

    @Test("Latest frame is retained until replaced")
    func latestFrameRetained() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        let buf1 = try #require(makeTestBuffer())
        tap.feed(buf1)
        #expect(tap.latestBuffer === buf1)

        let buf2 = try #require(makeTestBuffer())
        tap.feed(buf2)
        #expect(tap.latestBuffer === buf2)
    }

    @Test("Replacing frame releases old wrapper exactly once")
    func replacingReleasesOldOnce() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        let buf1 = try #require(makeTestBuffer())
        tap.feed(buf1)
        #expect(tap.latestBuffer === buf1)

        let buf2 = try #require(makeTestBuffer())
        tap.feed(buf2)
        #expect(tap.latestBuffer === buf2)
    }

    @Test("Dispose releases held wrapper exactly once")
    func disposeReleasesOnce() throws {
        var disposeCallCount = 0
        let tap = LiveComposeTap(sourceID: UUID(), onDispose: { @Sendable in
            MainActor.assumeIsolated { disposeCallCount += 1 }
        })
        let buf = try #require(makeTestBuffer())
        tap.feed(buf)
        #expect(tap.latestBuffer != nil)

        tap.dispose()
        #expect(tap.isDisposed)
        #expect(tap.latestBuffer == nil)
        #expect(disposeCallCount == 1)

        // Double dispose is a no-op.
        tap.dispose()
        #expect(disposeCallCount == 1)
    }

    @Test("Invisible source keeps latest frame warm")
    func invisibleKeepsWarm() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        let buf = try #require(makeTestBuffer())
        tap.feed(buf)

        // The tap still holds the frame even when the source is invisible.
        #expect(tap.latestBuffer !== nil)
        #expect(tap.latestBuffer === buf)
    }

    @Test("No-copy discipline: feed retains, not copies")
    func noCopyDiscipline() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        let buf = try #require(makeTestBuffer())
        tap.feed(buf)
        // The tap should retain the exact same buffer object, not a copy.
        #expect(tap.latestBuffer === buf)
    }

    @Test("Slow source remains available across scene switches")
    func slowSourceAvailableAcrossSwitches() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        let buf = try #require(makeTestBuffer())
        tap.feed(buf)

        // Simulate scene switches — the tap is never disposed during switches.
        for _ in 0..<10 {
            #expect(tap.latestBuffer === buf)
        }
    }

    @Test("Feed after dispose is no-op")
    func feedAfterDisposeNoop() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        tap.dispose()
        #expect(tap.isDisposed)

        let buf = try #require(makeTestBuffer())
        tap.feed(buf)
        #expect(tap.latestBuffer == nil)
    }

    @Test("Nil buffer initially")
    func nilInitially() {
        let tap = LiveComposeTap(sourceID: UUID())
        #expect(tap.latestBuffer == nil)
    }
}
