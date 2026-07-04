import Testing
import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import LocalCutCore
@testable import LocalCut_Studio

private final class PurgeableOverlaySource: OverlayFrameSource, @unchecked Sendable {
    nonisolated let naturalSize = CGSize(width: 8, height: 8)
    private let lock = NSLock()
    private var retainedFrames: Int

    init(cachedFrames: Int) {
        self.retainedFrames = cachedFrames
    }

    nonisolated var cachedFrameCount: Int {
        lock.withLock { retainedFrames }
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) async -> CIImage? {
        nil
    }

    nonisolated func purgeCachedFrames() {
        lock.withLock { retainedFrames = 0 }
    }
}

private func memoryPressureTestImage() -> CIImage {
    CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
}

@Suite("Memory pressure cache eviction", .serialized)
struct MemoryPressureHandlerTests {

    @Test("activate retains the memory-pressure dispatch source")
    func activateRetainsSource() {
        MemoryPressureHandler.shared.activate()
        #expect(MemoryPressureHandler.shared.isActive)
    }

    @Test("memory-pressure purge clears render, context, and overlay frame caches")
    func memoryPressurePurgeClearsCaches() throws {
        RenderCache.shared.purge()
        EffectCompositor.purgeContextCache()

        let cacheKey = RenderCacheKey(
            clipID: UUID(),
            effectChainHash: 42,
            time: .zero,
            renderSize: CGSize(width: 16, height: 16),
            workingColourSpace: .sRGB)
        RenderCache.shared.setImage(memoryPressureTestImage(), for: cacheKey)
        _ = EffectCompositor.context(for: .sRGB)

        let source = PurgeableOverlaySource(cachedFrames: 3)
        let registryID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): source],
            purpose: .preview))
        defer {
            EffectCompositor.releaseOverlaySources(for: registryID)
            RenderCache.shared.purge()
            EffectCompositor.purgeContextCache()
        }

        #expect(RenderCache.shared.count > 0)
        #expect(EffectCompositor.contextCacheCount > 0)
        #expect(source.cachedFrameCount == 3)

        MemoryPressureHandler.shared.purgeCachesForMemoryPressure()

        #expect(RenderCache.shared.count == 0)
        #expect(RenderCache.shared.currentBytes == 0)
        #expect(EffectCompositor.contextCacheCount == 0)
        #expect(source.cachedFrameCount == 0)
    }

    @Test("preview registry cleanup preserves the active preview and transient exports")
    func previewRegistryCleanupPreservesActiveAndTransient() throws {
        let activeID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): PurgeableOverlaySource(cachedFrames: 1)],
            purpose: .preview))
        let stalePreviewID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): PurgeableOverlaySource(cachedFrames: 1)],
            purpose: .preview))
        let transientID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): PurgeableOverlaySource(cachedFrames: 1)],
            purpose: .transient))
        defer {
            EffectCompositor.releaseOverlaySources(for: activeID)
            EffectCompositor.releaseOverlaySources(for: stalePreviewID)
            EffectCompositor.releaseOverlaySources(for: transientID)
        }

        EffectCompositor.releaseInactivePreviewOverlaySources(keeping: activeID)

        #expect(EffectCompositor.hasOverlaySourceRegistry(activeID))
        #expect(!EffectCompositor.hasOverlaySourceRegistry(stalePreviewID))
        #expect(EffectCompositor.hasOverlaySourceRegistry(transientID))
    }
}
