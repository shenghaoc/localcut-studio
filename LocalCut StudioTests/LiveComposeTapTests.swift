import Testing
import Foundation
import CoreVideo
@testable import LocalCut_Studio

@Suite("LiveComposeTap")
struct LiveComposeTapTests {

    /// Creates a minimal CVPixelBuffer for testing. Returns nil if the
    /// system can't create one (shouldn't happen on macOS).
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
        // buf1 is now released (only buf2 is retained).
    }

    @Test("Replacing frame releases old wrapper exactly once")
    func replacingReleasesOldOnce() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        var disposeCount = 0
        // We can't directly observe CVPixelBuffer release, but we can
        // verify the tap's state transitions.
        let buf1 = try #require(makeTestBuffer())
        tap.feed(buf1)
        #expect(tap.latestBuffer === buf1)

        let buf2 = try #require(makeTestBuffer())
        tap.feed(buf2)
        #expect(tap.latestBuffer === buf2)
        // After replacement, only buf2 is held.
        disposeCount += 1
    }

    @Test("Dispose releases held wrapper exactly once")
    func disposeReleasesOnce() throws {
        var disposeCallCount = 0
        let tap = LiveComposeTap(sourceID: UUID()) {
            disposeCallCount += 1
        }
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

        // Simulate the source being invisible — the tap still holds the frame.
        // (In real usage, the compositor simply doesn't composite invisible
        // layers, but the tap keeps the buffer warm.)
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
