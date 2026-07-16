import Testing
import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import os
import LocalCutCore
@testable import LocalCut_Studio
@testable import LocalCutPlatform

private nonisolated final class PurgeableOverlaySource: OverlayFrameSource, @unchecked Sendable {
    nonisolated let naturalSize = CGSize(width: 8, height: 8)
    private let lock = OSAllocatedUnfairLock(initialState: ())
    private var retainedFrames: Int

    init(cachedFrames: Int) {
        self.retainedFrames = cachedFrames
    }

    nonisolated var cachedFrameCount: Int {
        lock.withLock { _ in retainedFrames }
    }

    nonisolated func frame(at time: CMTime, endAction: OverlayEndAction) async -> CIImage? {
        nil
    }

    nonisolated func purgeCachedFrames() {
        lock.withLock { _ in retainedFrames = 0 }
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
        let paddedBackgroundImage = try #require(CIContext().createCGImage(
            memoryPressureTestImage(),
            from: CGRect(x: 0, y: 0, width: 16, height: 16)))
        PaddedBackgroundRenderer.cacheImage(
            paddedBackgroundImage,
            for: Data("padded-background".utf8),
            maxDimension: 16)

        let source = PurgeableOverlaySource(cachedFrames: 3)
        let transientSource = PurgeableOverlaySource(cachedFrames: 2)
        let registryID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): source],
            purpose: .preview))
        let transientRegistryID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): transientSource],
            purpose: .transient))
        defer {
            EffectCompositor.releaseOverlaySources(for: registryID)
            EffectCompositor.releaseOverlaySources(for: transientRegistryID)
            RenderCache.shared.purge()
            EffectCompositor.purgeContextCache()
            PaddedBackgroundRenderer.purgeCache()
        }

        #expect(RenderCache.shared.count > 0)
        #expect(EffectCompositor.contextCacheCount > 0)
        #expect(source.cachedFrameCount == 3)
        #expect(transientSource.cachedFrameCount == 2)
        #expect(PaddedBackgroundRenderer.cacheEntryCount == 1)

        MemoryPressureHandler.shared.purgeCachesForMemoryPressure()

        #expect(RenderCache.shared.count == 0)
        #expect(RenderCache.shared.currentBytes == 0)
        #expect(EffectCompositor.contextCacheCount == 0)
        #expect(source.cachedFrameCount == 0)
        #expect(transientSource.cachedFrameCount == 0)
        #expect(PaddedBackgroundRenderer.cacheEntryCount == 0)
    }

    @Test("padded-background cache remains bounded and retains the newest entry")
    func paddedBackgroundCacheRemainsBounded() throws {
        PaddedBackgroundRenderer.purgeCache()
        defer { PaddedBackgroundRenderer.purgeCache() }

        let image = try #require(CIContext().createCGImage(
            memoryPressureTestImage(),
            from: CGRect(x: 0, y: 0, width: 16, height: 16)))
        for index in 0..<9 {
            PaddedBackgroundRenderer.cacheImage(
                image,
                for: Data([UInt8(index)]),
                maxDimension: 16)
        }

        #expect(PaddedBackgroundRenderer.cacheEntryCount == 1)
        #expect(PaddedBackgroundRenderer.cachedImage(
            for: Data([8]),
            maxDimension: 16) != nil)
    }

    @Test("padded-background cache retains each render dimension independently")
    func paddedBackgroundCacheKeysByRenderDimension() throws {
        PaddedBackgroundRenderer.purgeCache()
        defer { PaddedBackgroundRenderer.purgeCache() }

        let context = CIContext()
        let preview = try #require(context.createCGImage(
            CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)),
            from: CGRect(x: 0, y: 0, width: 16, height: 16)))
        let export = try #require(context.createCGImage(
            CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)),
            from: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let bookmark = Data("shared-background".utf8)

        PaddedBackgroundRenderer.cacheImage(preview, for: bookmark, maxDimension: 16)
        PaddedBackgroundRenderer.cacheImage(export, for: bookmark, maxDimension: 32)

        #expect(PaddedBackgroundRenderer.cacheEntryCount == 2)
        #expect(PaddedBackgroundRenderer.cachedImage(for: bookmark, maxDimension: 16)?.width == 16)
        #expect(PaddedBackgroundRenderer.cachedImage(for: bookmark, maxDimension: 32)?.width == 32)
    }

    @Test("preview registry cleanup preserves active, in-flight, and transient registries")
    func previewRegistryCleanupPreservesActiveAndTransient() throws {
        let activeID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): PurgeableOverlaySource(cachedFrames: 1)],
            purpose: .preview))
        let stalePreviewID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): PurgeableOverlaySource(cachedFrames: 1)],
            purpose: .preview))
        let inFlightPreviewID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): PurgeableOverlaySource(cachedFrames: 1)],
            purpose: .preview))
        let transientID = try #require(EffectCompositor.registerOverlaySources(
            [UUID(): PurgeableOverlaySource(cachedFrames: 1)],
            purpose: .transient))
        defer {
            EffectCompositor.releaseOverlaySources(for: activeID)
            EffectCompositor.releaseOverlaySources(for: stalePreviewID)
            EffectCompositor.releaseOverlaySources(for: inFlightPreviewID)
            EffectCompositor.releaseOverlaySources(for: transientID)
        }

        EffectCompositor.releaseInactivePreviewOverlaySources(
            keeping: activeID,
            excluding: [inFlightPreviewID])

        #expect(EffectCompositor.hasOverlaySourceRegistry(activeID))
        #expect(!EffectCompositor.hasOverlaySourceRegistry(stalePreviewID))
        #expect(EffectCompositor.hasOverlaySourceRegistry(inFlightPreviewID))
        #expect(EffectCompositor.hasOverlaySourceRegistry(transientID))
    }
}
