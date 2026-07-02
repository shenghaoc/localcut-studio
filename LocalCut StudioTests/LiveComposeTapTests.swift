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

    @Test("Feed returns the active frame without copying")
    func feedReturnsActiveFrame() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        let buf = try #require(makeTestBuffer())
        let accepted = try #require(tap.feed(buf))
        #expect(accepted === buf)
    }

    @Test("Dispose fires callback exactly once")
    func disposeFiresOnce() throws {
        var disposeCallCount = 0
        let tap = LiveComposeTap(sourceID: UUID(), onDispose: { @Sendable in
            MainActor.assumeIsolated { disposeCallCount += 1 }
        })

        tap.dispose()
        #expect(tap.isDisposed)
        #expect(disposeCallCount == 1)

        // Double dispose is a no-op.
        tap.dispose()
        #expect(disposeCallCount == 1)
    }

    @Test("Feed after dispose is dropped")
    func feedAfterDisposeDropsFrame() throws {
        let tap = LiveComposeTap(sourceID: UUID())
        tap.dispose()
        #expect(tap.isDisposed)

        let buf = try #require(makeTestBuffer())
        #expect(tap.feed(buf) == nil)
    }
}
