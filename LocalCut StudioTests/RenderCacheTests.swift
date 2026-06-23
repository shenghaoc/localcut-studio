import Testing
import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
@testable import LocalCut_Studio

// MARK: - Helpers

/// Cropped CIImage with a known bounded extent so byte-budget assertions can be
/// made against the image's actual extent (which is what `RenderCache.setImage`
/// uses to size the entry). Default 100×100 keeps eviction-order tests
/// arithmetically tidy.
private func tinyImage(width: CGFloat = 100, height: CGFloat = 100) -> CIImage {
    CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

private func key(clipID: UUID = UUID(),
                 effectChainHash: Int = 0,
                 time: CMTime = .zero,
                 renderSize: CGSize = CGSize(width: 1920, height: 1080)) -> RenderCacheKey {
    RenderCacheKey(clipID: clipID, effectChainHash: effectChainHash,
                   time: time, renderSize: renderSize)
}

private func temporaryRenderCacheDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalCutStudioTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - R1: Composite key

@Test("RenderCacheKey: equal when every field matches")
func keyEqualsWhenAllFieldsMatch() {
    let id = UUID()
    let t = CMTime(value: 30, timescale: 600)
    let s = CGSize(width: 1920, height: 1080)
    let a = RenderCacheKey(clipID: id, effectChainHash: 42, time: t, renderSize: s)
    let b = RenderCacheKey(clipID: id, effectChainHash: 42, time: t, renderSize: s)
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
}

@Test("RenderCacheKey: every field is part of identity")
func keyDistinctOnAnyFieldChange() {
    let base = key(clipID: UUID(), effectChainHash: 1,
                   time: CMTime(value: 30, timescale: 600),
                   renderSize: CGSize(width: 1920, height: 1080))
    #expect(base != key(clipID: UUID(), effectChainHash: 1,
                        time: CMTime(value: 30, timescale: 600),
                        renderSize: CGSize(width: 1920, height: 1080)))
    let sameClip = base.clipID
    #expect(base != RenderCacheKey(clipID: sameClip, effectChainHash: 2,
                                   time: CMTime(value: 30, timescale: 600),
                                   renderSize: CGSize(width: 1920, height: 1080)))
    #expect(base != RenderCacheKey(clipID: sameClip, effectChainHash: 1,
                                   time: CMTime(value: 31, timescale: 600),
                                   renderSize: CGSize(width: 1920, height: 1080)))
    #expect(base != RenderCacheKey(clipID: sameClip, effectChainHash: 1,
                                   time: CMTime(value: 30, timescale: 600),
                                   renderSize: CGSize(width: 1280, height: 720)))
}

@Test("RenderCacheKey: normalises CMTime to the microsecond timescale")
func keyNormalisesTimescale() {
    let k = key(time: CMTime(value: 30, timescale: 600))
    #expect(k.timeScale == RenderCacheKey.normalisedTimescale)
    // 30/600 = 0.05 s = 50_000 µs.
    #expect(k.timeValue == 50_000)
    #expect(k.time.seconds == 0.05)
}

@Test("RenderCacheKey: equivalent times in different timescales collapse to one key (Gemini review)")
func keyCollapsesEquivalentTimescales() {
    let id = UUID()
    let chainHash = 7
    let size = CGSize(width: 1920, height: 1080)
    // 0.5 s expressed three ways.
    let a = RenderCacheKey(clipID: id, effectChainHash: chainHash,
                           time: CMTime(value: 1, timescale: 2),
                           renderSize: size)
    let b = RenderCacheKey(clipID: id, effectChainHash: chainHash,
                           time: CMTime(value: 2, timescale: 4),
                           renderSize: size)
    let c = RenderCacheKey(clipID: id, effectChainHash: chainHash,
                           time: CMTime(value: 15, timescale: 30),
                           renderSize: size)
    #expect(a == b)
    #expect(a == c)
}

@Test("RenderCacheKey: invalid CMTime falls back to a zero-time normalised key")
func keyGuardsAgainstInvalidCMTime() {
    let k = key(time: CMTime(value: 5, timescale: 0))
    #expect(k.timeScale == RenderCacheKey.normalisedTimescale)
    #expect(k.timeValue == 0)
}

// MARK: - R1.2 / R7.6: Effect chain hash

@Test("[Effect].renderCacheHash: empty chain has a deterministic value")
func chainHashEmptyDeterministic() {
    let a: [Effect] = []
    let b: [Effect] = []
    #expect(a.renderCacheHash == b.renderCacheHash)
}

@Test("[Effect].renderCacheHash: identical chains hash equal")
func chainHashIdenticalEqual() {
    let chain: [Effect] = [.colourGrade(.neutral)]
    #expect(chain.renderCacheHash == chain.renderCacheHash)
}

@Test("[Effect].renderCacheHash: differs when colour grade changes")
func chainHashChangesOnGradeChange() {
    var grade = ColourGrade()
    grade.exposure = 0.5
    let a: [Effect] = [.colourGrade(.neutral)]
    let b: [Effect] = [.colourGrade(grade)]
    #expect(a.renderCacheHash != b.renderCacheHash)
}

@Test("[Effect].renderCacheHash: differs when chain order changes")
func chainHashChangesOnReorder() {
    let lut = Effect.lut(bookmark: Data([0x01, 0x02]))
    let grade = Effect.colourGrade(.neutral)
    let a: [Effect] = [lut, grade]
    let b: [Effect] = [grade, lut]
    #expect(a.renderCacheHash != b.renderCacheHash)
}

@Test("[Effect].renderCacheHash: differs when LUT bookmark bytes change")
func chainHashChangesOnLUTBytes() {
    let a: [Effect] = [.lut(bookmark: Data([0x01]))]
    let b: [Effect] = [.lut(bookmark: Data([0x02]))]
    #expect(a.renderCacheHash != b.renderCacheHash)
}

// MARK: - R2 / R7.1: LRU cache hit / miss

@Test("RenderCache: hit on identical key returns the cached image")
func cacheHitOnIdentical() {
    let cache = RenderCache()
    let k = key()
    let image = tinyImage()
    cache.setImage(image, for: k)
    let hit = cache.image(for: k)
    #expect(hit === image)
}

@Test("RenderCache: miss when clipID differs")
func cacheMissOnClipChange() {
    let cache = RenderCache()
    let original = key(clipID: UUID(), effectChainHash: 1)
    cache.setImage(tinyImage(), for: original)
    let probe = RenderCacheKey(clipID: UUID(), effectChainHash: 1,
                               time: original.time, renderSize: original.renderSize)
    #expect(cache.image(for: probe) == nil)
}

@Test("RenderCache: miss when effectChainHash differs")
func cacheMissOnChainChange() {
    let cache = RenderCache()
    let original = key(effectChainHash: 1)
    cache.setImage(tinyImage(), for: original)
    let probe = RenderCacheKey(clipID: original.clipID, effectChainHash: 2,
                               time: original.time, renderSize: original.renderSize)
    #expect(cache.image(for: probe) == nil)
}

@Test("RenderCache: miss when time differs")
func cacheMissOnTimeChange() {
    let cache = RenderCache()
    let original = key(time: CMTime(value: 30, timescale: 600))
    cache.setImage(tinyImage(), for: original)
    let probe = RenderCacheKey(clipID: original.clipID,
                               effectChainHash: original.effectChainHash,
                               time: CMTime(value: 31, timescale: 600),
                               renderSize: original.renderSize)
    #expect(cache.image(for: probe) == nil)
}

@Test("RenderCache: miss when renderSize differs")
func cacheMissOnSizeChange() {
    let cache = RenderCache()
    let original = key(renderSize: CGSize(width: 1920, height: 1080))
    cache.setImage(tinyImage(), for: original)
    let probe = RenderCacheKey(clipID: original.clipID,
                               effectChainHash: original.effectChainHash,
                               time: original.time,
                               renderSize: CGSize(width: 1280, height: 720))
    #expect(cache.image(for: probe) == nil)
}

@Test("RenderCache: re-insert at the same key replaces, doesn't stack bytes")
func cacheReinsertReplaces() {
    let cache = RenderCache()
    let k = key(renderSize: CGSize(width: 100, height: 100))
    let perEntry = RenderCache.estimatedBytes(width: 100, height: 100)
    cache.setImage(tinyImage(), for: k)
    cache.setImage(tinyImage(), for: k)
    #expect(cache.count == 1)
    #expect(cache.currentBytes == perEntry)
}

// MARK: - R3 / R7.3: Byte-budget eviction

@Test("RenderCache: byte-budget evicts the least-recently-used entry")
func cacheEvictsLRU() {
    // 100x100 entries → 40,000 bytes each. Budget = 2 entries' worth.
    let perEntry = RenderCache.estimatedBytes(width: 100, height: 100)
    let cache = RenderCache(byteBudget: perEntry * 2, diskByteBudget: 0)
    let size = CGSize(width: 100, height: 100)
    let k1 = key(clipID: UUID(), renderSize: size)
    let k2 = key(clipID: UUID(), renderSize: size)
    let k3 = key(clipID: UUID(), renderSize: size)

    cache.setImage(tinyImage(), for: k1)
    cache.setImage(tinyImage(), for: k2)
    // Touch k1 so it becomes most-recently-used; k2 is now LRU.
    _ = cache.image(for: k1)
    cache.setImage(tinyImage(), for: k3)

    #expect(cache.count == 2)
    #expect(cache.image(for: k1) != nil)
    #expect(cache.image(for: k2) == nil, "k2 was least-recently-used and should be evicted")
    #expect(cache.image(for: k3) != nil)
}

@Test("RenderCache: evicted frames spill to disk and rehydrate on lookup")
func cacheDiskSpillRehydrates() throws {
    let directory = try temporaryRenderCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let perEntry = RenderCache.estimatedBytes(width: 16, height: 16)
    let cache = RenderCache(byteBudget: perEntry,
                            diskByteBudget: 1_000_000,
                            cacheDirectory: directory)
    let size = CGSize(width: 16, height: 16)
    let k1 = key(clipID: UUID(), renderSize: size)
    let k2 = key(clipID: UUID(), renderSize: size)

    cache.setImage(tinyImage(width: 16, height: 16), for: k1)
    cache.setImage(tinyImage(width: 16, height: 16), for: k2)

    #expect(cache.count == 1)
    #expect(cache.diskCount == 1)
    #expect(cache.currentDiskBytes > 0)

    let rehydrated = cache.image(for: k1)
    #expect(rehydrated != nil)
    #expect(cache.count == 1)
    #expect(cache.diskCount >= 1)

    cache.purge()
    #expect(cache.count == 0)
    #expect(cache.diskCount == 0)
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
    #expect(remaining.isEmpty)
}

@Test("RenderCache: byte cost reflects the stored image's extent, not the key's renderSize (Claude review)")
func byteCostFromImageExtent() {
    // A 4K source frame rendered onto a 1080p canvas is stored at the source's
    // 3840×2160 extent (the materialised CGImage), not at the key's 1920×1080
    // render size. Sizing the cost off the key would silently let the byte
    // budget hold 4× more pixels than declared.
    let cache = RenderCache()
    let sourceImage = tinyImage(width: 3840, height: 2160)
    let k = key(renderSize: CGSize(width: 1920, height: 1080))
    cache.setImage(sourceImage, for: k)

    #expect(cache.currentBytes == RenderCache.estimatedBytes(width: 3840, height: 2160))
    #expect(cache.currentBytes != RenderCache.estimatedBytes(
        width: k.renderWidth, height: k.renderHeight))
}

@Test("RenderCache: currentBytes tracks insert and eviction")
func cacheTracksBytes() {
    let perEntry = RenderCache.estimatedBytes(width: 100, height: 100)
    let cache = RenderCache(byteBudget: perEntry * 2)
    let size = CGSize(width: 100, height: 100)
    cache.setImage(tinyImage(), for: key(clipID: UUID(), renderSize: size))
    #expect(cache.currentBytes == perEntry)
    cache.setImage(tinyImage(), for: key(clipID: UUID(), renderSize: size))
    #expect(cache.currentBytes == perEntry * 2)
    cache.setImage(tinyImage(), for: key(clipID: UUID(), renderSize: size))
    #expect(cache.currentBytes == perEntry * 2, "Total stays at budget after eviction")
}

// MARK: - R4 / R7.4: Invalidation

@Test("RenderCache: invalidate(clipID:) drops only matching entries")
func invalidateClipID() {
    let cache = RenderCache()
    let editedClip = UUID()
    let otherClip = UUID()
    let editedKey1 = key(clipID: editedClip, effectChainHash: 1)
    let editedKey2 = key(clipID: editedClip, effectChainHash: 2,
                         time: CMTime(value: 30, timescale: 600))
    let otherKey = key(clipID: otherClip, effectChainHash: 1)

    cache.setImage(tinyImage(), for: editedKey1)
    cache.setImage(tinyImage(), for: editedKey2)
    cache.setImage(tinyImage(), for: otherKey)
    #expect(cache.count == 3)

    cache.invalidate(clipID: editedClip)

    #expect(cache.image(for: editedKey1) == nil)
    #expect(cache.image(for: editedKey2) == nil)
    #expect(cache.image(for: otherKey) != nil)
    #expect(cache.count == 1)
    // One 100×100 image remains; byte cost is image-extent driven.
    #expect(cache.currentBytes == RenderCache.estimatedBytes(width: 100, height: 100))
}

@Test("RenderCache: invalidate(notMatchingRenderSize:) drops stale-canvas entries")
func invalidateRenderSize() {
    let cache = RenderCache()
    let smallKey = key(clipID: UUID(), renderSize: CGSize(width: 1280, height: 720))
    let bigKey = key(clipID: UUID(), renderSize: CGSize(width: 1920, height: 1080))
    cache.setImage(tinyImage(), for: smallKey)
    cache.setImage(tinyImage(), for: bigKey)

    cache.invalidate(notMatchingRenderSize: CGSize(width: 1920, height: 1080))

    #expect(cache.image(for: smallKey) == nil)
    #expect(cache.image(for: bigKey) != nil)
}

@Test("RenderCache: cache survives a composition rebuild but not an effect-chain edit")
func cacheSurvivesRebuildNotEffectEdit() {
    // Simulates the integration semantics: a composition rebuild does not
    // touch the cache, so a prior post-effect frame still hits; an effect-
    // chain edit, however, calls invalidate(clipID:) and the prior frame
    // becomes a miss.
    let cache = RenderCache()
    let clipID = UUID()
    let beforeEdit = key(clipID: clipID, effectChainHash: 0xCAFE)
    cache.setImage(tinyImage(), for: beforeEdit)

    // "Composition rebuild" — no cache call. Lookup still hits.
    #expect(cache.image(for: beforeEdit) != nil)

    // "Effect-chain edit" — editor invalidates by clipID.
    cache.invalidate(clipID: clipID)
    #expect(cache.image(for: beforeEdit) == nil)
}

@Test("RenderCache: purge() empties the cache and resets bytes")
func cachePurgeEmpties() {
    let cache = RenderCache()
    cache.setImage(tinyImage(), for: key())
    cache.setImage(tinyImage(), for: key())
    #expect(cache.count > 0)
    cache.purge()
    #expect(cache.count == 0)
    #expect(cache.currentBytes == 0)
}

// MARK: - R6: Storage location

// MARK: - Editor integration (codex review P2 — slider path)

/// These tests poke `RenderCache.shared`, so serialise them so two of them
/// running in parallel don't clobber each other's pre-asserted state.
@MainActor
@Suite("EditorModel ↔ RenderCache (slider path)", .serialized)
struct EditorRenderCacheIntegrationTests {

    private func makeModel() -> (EditorModel, Clip.ID) {
        let model = EditorModel()
        let media = MediaItem(url: URL(fileURLWithPath: "/dev/null"))
        media.duration = CMTime(seconds: 5, preferredTimescale: 600)
        media.hasVideo = true
        model.project.mediaItems.append(media)
        let clip = Clip(mediaID: media.id,
                        sourceStart: .zero,
                        duration: CMTime(seconds: 5, preferredTimescale: 600),
                        timelineStart: .zero)
        model.project.videoTracks.first!.clips.append(clip)
        model.selectedClipID = clip.id
        return (model, clip.id)
    }

    @Test("Opacity-only mutation through updateSelectedClipCoalesced does NOT invalidate the cache")
    func opacityDragKeepsCache() {
        let (model, clipID) = makeModel()
        let k = RenderCacheKey(clipID: clipID, effectChainHash: 0,
                               time: .zero,
                               renderSize: CGSize(width: 1920, height: 1080))
        RenderCache.shared.purge()
        RenderCache.shared.setImage(tinyImage(), for: k)

        model.updateSelectedClipCoalesced("Adjust Opacity") { $0.opacity = 0.5 }

        #expect(RenderCache.shared.image(for: k) != nil,
                "Opacity-only edits flow through the post-chain compositor stage; cache should survive")
        RenderCache.shared.purge()
    }

    @Test("Changing effects through updateSelectedClipCoalesced invalidates the cache (codex review P2)")
    func effectEditDropsCache() {
        let (model, clipID) = makeModel()
        let k = RenderCacheKey(clipID: clipID, effectChainHash: 0,
                               time: .zero,
                               renderSize: CGSize(width: 1920, height: 1080))
        RenderCache.shared.purge()
        RenderCache.shared.setImage(tinyImage(), for: k)

        // Same path the Inspector colour sliders use.
        model.updateSelectedClipCoalesced("Adjust Colour") { c in
            c.effects.append(.colourGrade(.neutral))
        }

        #expect(RenderCache.shared.image(for: k) == nil,
                "Effect-chain changes must drop matching cache entries even via the generic helper")
        RenderCache.shared.purge()
    }
}

// MARK: - Storage location

@Test("RenderCache.cacheDirectoryURL: ends in bundle-scoped RenderCache/ path")
func cacheDirectoryHasBundleScope() {
    guard let url = RenderCache.cacheDirectoryURL else {
        Issue.record("Caches directory should be resolvable in the test runner")
        return
    }
    #expect(url.lastPathComponent == "RenderCache")
    // The parent is the bundle-id-scoped subfolder (`com.shenghaoc.…` in
    // production; the test bundle id under xcodebuild).
    let parent = url.deletingLastPathComponent().lastPathComponent
    #expect(!parent.isEmpty)
    #expect(url.path.contains("/Caches/"))
}
