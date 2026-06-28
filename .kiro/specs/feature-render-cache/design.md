# Design: Render Cache (P19 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 35 (speed ramps) and Phase 37 (frame interpolation via `VTFrameProcessor`).

## Goal

Memoise the **post-effect-chain** image of each video clip so the per-clip CIFilter pipeline runs at most once per `(clip, effect chain, time, render size, working colour space)` tuple. Speed ramps re-fetch the same source-frame time several times per output frame and frame interpolation reads each neighbour twice; without a cache the chain would re-execute every time, blowing past the budget the preview path can spend on each frame.

The cache sits **inside `EffectCompositor`**, replacing the per-frame `applyEffectChain(_:effects:)` body with a memoised one. Preview and export share the compositor, so they share the cache — Phase 35 / 37 do not need a second copy on either side.

## Approach

1. **Composite key.** A frame is uniquely identified by *which clip* produced it, *what effects* the chain applied, *when in the source media* we were, *what canvas* we were rendering into, and *which working colour space* materialised it. Each axis maps to one field of `RenderCacheKey`. The time field is the **source-frame time** (computed from `sourceRange` / `timeRange`), not `compositionTime` — this makes the key stable across repeated source-frame requests (speed ramps, frame interpolation) and unique per source frame (no collisions across pieces of the same clip split by transition cuts).
2. **In-memory LRU.** An `OSAllocatedUnfairLock`-guarded dictionary plus lock-confined doubly-linked list. Most-recently-used entries live at the tail; the head is dropped first. Lookup touch and eviction are O(1).
3. **Byte-budget eviction.** Frames are large (8 MiB at 1080p, 33 MiB at 4K) and *variable* (project resize jumps an entry's footprint by 4×), so the cap is total estimated bytes, not entry count.
4. **Disk spill.** Evicted memory entries are PNG-encoded into the sandbox Caches directory, tracked by a second bounded LRU, and rehydrated into memory on miss.
5. **Cache-key invalidation.** Effect-chain edits change `effectChainHash`, so a new request never collides with a stale entry — correctness is automatic. Explicit `invalidate(clipID:)` and `invalidate(notMatchingRenderSize:)` release dead memory entries and spill files promptly when the editor knows a clip's effects mutated or the canvas resized.

## Types

```swift
nonisolated struct RenderCacheKey: Hashable, Sendable {
    let clipID: UUID
    let effectChainHash: Int      // Hasher digest of [Effect]; same approach
                                  // CaptionStyle.rasterHash uses.
    let timeValue: Int64          // CMTime, normalised to a microsecond
                                  // timescale so equivalent times in
                                  // different timescales collapse to one
                                  // key (Gemini review).
    let timeScale: Int32          // Always `normalisedTimescale` (1_000_000).
    let renderWidth: Int
    let renderHeight: Int
    let workingColourSpace: WorkingColourSpace
}

final class RenderCache: @unchecked Sendable {
    static let shared: RenderCache
    init(byteBudget: Int)

    func image(for key: RenderCacheKey) -> CIImage?
    func setImage(_ image: CIImage, for key: RenderCacheKey)

    func invalidate(clipID: UUID)
    func invalidate(notMatchingRenderSize: CGSize)
    func purge()
}

extension Array where Element == Effect {
    var renderCacheHash: Int      // Hasher digest of the chain, in order.
}
```

`CompositorLayer` gains `clipID: UUID`, `sourceRange: CMTimeRange`, and `timeRange: CMTimeRange` so the compositor can compute the source-frame time for the key without reaching back into the composition. `CompositionBuilder.VideoSegment` already knows the originating clip and piece ranges; they propagate one extra hop into `CompositorLayer.init(clipID:trackID:transform:opacity:effects:showSkinMask:clipStartTime:sourceRange:timeRange:)`.

## Cache

`OSAllocatedUnfairLock<CacheState>` where:

```swift
private struct CacheState {
    var entries: [RenderCacheKey: RenderCacheEntry]
    var memoryNodes: [RenderCacheKey: MemoryNode]
    var memoryHead: MemoryNode?      // least-recent
    var memoryTail: MemoryNode?      // MRU
    var totalBytes: Int
    var diskEntries: [RenderCacheKey: DiskEntry]
    var diskNodes: [RenderCacheKey: DiskNode]
    var diskHead: DiskNode?
    var diskTail: DiskNode?
    var diskBytes: Int
}

private struct RenderCacheEntry: Sendable {
    let image: CIImage
    let byteCost: Int                // image.extent.width × .height × 4 (BGRA).
                                     // Source-extent-based, not key-renderSize-based:
                                     // a 4K source rendered onto a 1080p canvas
                                     // stores ~33 MiB, not the ~8 MiB the canvas
                                     // suggests, so sizing the cost off the key
                                     // would leak 4× the declared budget.
}
```

Lookup touches the matched memory node to the tail. Insert appends a memory node and pops the head until `totalBytes ≤ byteBudget`. Evicted entries are written outside the lock, then recorded in the disk LRU. A memory miss checks the disk index, loads the PNG via `CIImage(contentsOf:)`, and re-inserts into memory. `invalidate(clipID:)`, `invalidate(notMatchingRenderSize:)`, and `purge()` remove both memory entries and spill files.

### Storage tiers

- **In-memory (this spec)** — primary tier; budget defaults to 256 MiB so a 1080p project can hold ~32 frames before LRU starts evicting. Tunable via `init(byteBudget:)` so the diagnostics panel (P25) can dial it down on lower-RAM Macs.
- **Disk spill** — `RenderCache.cacheDirectoryURL` resolves the sandbox-allowed path
  `~/Library/Caches/com.shenghaoc.LocalCutStudio/RenderCache/`
  via `FileManager.url(for: .cachesDirectory, in: .userDomainMask, ...)`. App Sandbox grants the container Caches directly per ROADMAP's "Apple API spot-checks", so no security-scoped bookmark is needed. Evicted entries are written as PNG using a dedicated `CIContext`; the disk tier defaults to 1 GiB, has its own LRU, and is process-local because `effectChainHash` is process-seeded.

## Compositor integration

`EffectCompositor.applyEffectChain(_:effects:cacheKey:at:)` consults `RenderCache.shared` before iterating the chain; on a hit it returns the cached image untouched and the per-clip filters never run. On a miss it executes the existing pipeline and **materialises** the result into a CGImage-backed `CIImage` through the instruction's working-colour-space `CIContext` before writing it back — a lazy `CIImage` filter graph would force `CIContext.render` to re-evaluate the colour / LUT / skin-smooth kernels on every hit, so Phase 35 / 37's repeated-frame requests would still pay the work this cache exists to avoid (codex review P1). The cache is consulted **after** the source `CIImage(cvPixelBuffer:)` materialisation and **before** the layer's fit transform / opacity — those are cheap and frame-size sensitive, so caching them would balloon the entry space without saving meaningful work.

```swift
nonisolated private func applyEffectChain(_ image: CIImage,
                                          effects: [Effect],
                                          cacheKey: RenderCacheKey?,
                                          at time: CMTime = .zero) -> CIImage {
    if effects.isEmpty { return image }                          // nothing to memoise
    if let cacheKey, let cached = RenderCache.shared.image(for: cacheKey) {
        return cached
    }
    let sourceExtent = image.extent
    var result = image
    var allEffectsApplied = true
    for effect in effects {
        switch effect {
        case .lut(bookmark: let data):
            if let next = applyLUT(result, bookmarkData: data) {
                result = next
            } else {
                allEffectsApplied = false  // codex review P2: transient
                                           // LUT-load failure must not
                                           // cache the un-LUT'ed image,
                                           // or the LUTCache's retry path
                                           // would never reach this frame.
            }
        /* other cases unchanged */
        }
    }
    guard let cacheKey, allEffectsApplied,
          let materialised = materialise(result, extent: sourceExtent) else {
        return result
    }
    RenderCache.shared.setImage(materialised, for: cacheKey)
    return materialised
}
```

`renderedImage(for layer:, request:)` builds the key from the layer's `clipID`, the chain's `renderCacheHash`, a **source-frame time** computed from `layer.sourceRange` and `layer.timeRange` (not `request.compositionTime`), `request.renderContext.size`, and the instruction's `workingColourSpace`. When `effects.isEmpty` the key is `nil` — there is nothing to cache. The skin-mask debug visualisation (`layer.showSkinMask`) bypasses the cache entirely: it produces a one-off debug image that must not be served back on a normal preview after the toggle.

## Invalidation

| Editor action | Cache action |
|---|---|
| `updateSelectedClipCoalesced` (the Inspector slider path) | `invalidate(clipID:)` iff the closure changed `effects` — opacity drags do not invalidate (codex review P2) |
| `selectedClipGrade` setter / `selectedClipSkinSmooth` setter | `invalidate(clipID:)` for the edited clip |
| `resetClipColourEffects` / `resetClipSkinSmooth` | `invalidate(clipID:)` for the edited clip |
| `updateSelectedClipSkinSmooth` | `invalidate(clipID:)` for the edited clip |
| `importLUT` | `invalidate(clipID:)` for the edited clip |
| `setRenderSize` | `invalidate(notMatchingRenderSize:)` with the new size |
| Session swap (`releaseSession`) | `purge()` |
| Composition rebuild (no effect / size change) | none — cache survives |
| Undo / redo of an effect edit | none directly; the restored chain's `effectChainHash` differs from the one in the cache, so the next lookup misses on key-equality grounds. The stale entries age out of the byte budget via LRU. |

The combination of explicit invalidation on the obvious paths *and* automatic key-divergence on the indirect ones (undo, document open) means correctness never relies on the editor enumerating every mutation site. The diff-check inside `updateSelectedClipCoalesced` matters because the Inspector's colour sliders route through that helper (not through `selectedClipGrade`'s setter) — invalidating unconditionally there would defeat the cache on opacity drags.

## Trade-offs

- **Cache after source decode, before fit transform.** Caching the post-transform image would force a separate entry per layer geometry; caching pre-decode would force the cache to hold raw `CVPixelBuffer`s that AVFoundation has already paid the cost to deliver. The post-chain image is the highest-value cut.
- **Byte budget vs entry count.** A 1080p frame is 8 MiB, a 4K frame 33 MiB; an entry-count cap that fits a 4K timeline would be 4× too large for a 1080p one. The byte budget normalises across project sizes and follows TitleRasterer's "the cost is the work, not the count" principle inverted (TitleRasterer caps entries because rasters are tiny; this cache caps bytes because frames are not).
- **Process-local in-run hash.** `Hasher` seeds per-process, so `renderCacheHash` is **not** stable across launches — the cache is purely in-memory and re-warms from scratch on relaunch, so this is fine.
- **Singleton, not per-EditorModel.** The compositor is created by AVFoundation per render pass, so the cache has to outlive any single compositor instance. A shared singleton matches the existing `sharedCaptionRasterer` shape and keeps preview and export sharing one warm cache.

## Risks

- A leaked `CIImage` whose backing buffer transitively retains a `CVPixelBuffer` could pin the source decoder's frame; in practice AVFoundation reissues source frames per request, so the cached `CIImage` only holds CPU-side filter graph metadata, not the buffer.
- A pathological project (thousands of clips, all with chains) inserting into the cache faster than LRU can drop entries can briefly exceed the byte budget in the eviction window; we accept the overshoot because the cap is advisory, not a hard memory limit.
- Two clips that legitimately share `(effectChainHash, time, renderSize)` but differ only in `clipID` are kept as separate entries. This is correct (clipID is in the key) but loses a possible deduplication win — Phase 38's look packs may revisit this once shared LUTs become common.

## Non-goals

- **Cross-launch disk persistence** (`Hasher` is process-seeded, so spill files are only an in-session acceleration tier).
- **Pre-decode `CVPixelBuffer` caching** (AVFoundation already owns this layer; we would only thrash it).
- **Cross-process / cross-launch persistence** (`Hasher` is process-seeded; preserving a digest across launches would need a hand-rolled stable hash on every `Effect` case).
- **Cache-warm prediction** (Phase 35 may add a pre-warm helper; this spec stays reactive).
- **Caching the layer's post-transform / post-opacity image** (geometry-sensitive; would multiply entry count without saving the filter work that actually costs).
