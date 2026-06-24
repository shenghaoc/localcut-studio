# Requirements: Render Cache

> Status: **Implemented**. P19 native equivalent; prerequisite for Phase 35 (speed ramps) and Phase 37 (frame interpolation).

## R1 — Composite key

- **R1.1** A `RenderCacheKey` identifies one cached post-effect-chain frame by `(clipID: UUID, effectChainHash: Int, time: CMTime, renderSize: CGSize)`. The `time` field is the **source-frame time** computed from the layer's `sourceRange` / `timeRange`, not the raw `compositionTime` — this makes the key stable across repeated source-frame requests (speed ramps, frame interpolation) and unique per source frame (no collisions across pieces of the same clip split by transition cuts).
- **R1.2** `effectChainHash` is derived from `[Effect]` using a `Hasher`, the same approach `CaptionStyle.rasterHash` uses.
- **R1.3** Two keys are equal iff every field matches. Changing any field produces a distinct key.
- **R1.4** `CMTime` is normalised to a high-precision microsecond timescale before being stored, so equivalent times in different timescales (e.g. `1/2` s vs `15/30` s) produce the same key.

## R2 — Cache shape

- **R2.1** The cache is an LRU keyed exactly on `RenderCacheKey`.
- **R2.2** Lookup touches the matched entry to the most-recently-used position.
- **R2.3** The primary cache is in memory; evicted entries spill to a bounded disk tier and rehydrate on lookup.
- **R2.4** Inserts and lookups are thread-safe (`OSAllocatedUnfairLock`).

## R3 — Byte budget

- **R3.1** The cap is a total estimated byte budget, not an entry count. Default 256 MiB; configurable via `init(byteBudget:)`.
- **R3.2** Per-entry cost is sized off the **stored image's actual extent** (width × height × 4 BGRA). A 4K source frame rendered onto a 1080p canvas costs ~33 MiB, not the ~8 MiB the render canvas would suggest — using the key's `renderSize` for accounting would silently let the budget hold 4× more pixels than declared. The key-based estimate is the fallback for degenerate (infinite / null / empty) extents.
- **R3.3** On insert past the budget, the least-recently-used entries are evicted until `totalBytes ≤ byteBudget`.
- **R3.4** Re-inserting an existing key replaces (not stacks) the prior entry; `totalBytes` is decremented for the prior entry and incremented for the new one.

## R4 — Invalidation

- **R4.1** `invalidate(clipID:)` removes every entry whose key matches the given clip.
- **R4.2** `invalidate(notMatchingRenderSize:)` removes every entry whose render size is not the given size.
- **R4.3** `purge()` empties the cache and resets `totalBytes` to zero.
- **R4.4** Effect-chain edits in the editor call `invalidate(clipID:)` for the affected clip, **including the generic `updateSelectedClipCoalesced` slider path** (Inspector colour sliders flow through it). The helper diff-checks `effects` so opacity-only drags do not invalidate.
- **R4.5** A project render-size change in the editor calls `invalidate(notMatchingRenderSize:)` after the size is applied.
- **R4.6** A session swap (`releaseSession`) calls `purge()`.

## R5 — Compositor integration

- **R5.1** `EffectCompositor.applyEffectChain` consults the cache before executing the CIFilter chain. The cache key's `time` field is the source-frame time derived from `layer.sourceRange` and `layer.timeRange`, not `request.compositionTime`.
- **R5.2** A cache hit returns the cached image and does not run the chain.
- **R5.3** A cache miss runs the chain, **materialises the result into a CGImage-backed `CIImage`** (forcing kernel evaluation once), then writes that back. A later cache hit therefore avoids the kernel work, not just the Swift filter-chain construction.
- **R5.4** When `effects.isEmpty`, the cache is not consulted and nothing is written — there is nothing to memoise.
- **R5.5** When any effect in the chain fails to apply (e.g. a transiently-unreadable LUT bookmark), the cache is not written — the next request must re-attempt the chain so the recovered effect reaches the frame.
- **R5.6** The skin-mask debug visualisation (`layer.showSkinMask`) bypasses the cache entirely — it produces a one-off debug image that must not be served back on a normal preview after the toggle.
- **R5.7** `CompositorLayer` carries `clipID`, `sourceRange`, and `timeRange` so the compositor can compute the source-frame time for the key without reaching back into the composition.

## R6 — Storage location

- **R6.1** `RenderCache.cacheDirectoryURL` resolves to a sandbox-allowed path under `FileManager.url(for: .cachesDirectory, in: .userDomainMask, ...)` scoped to `com.shenghaoc.LocalCutStudio/RenderCache/`.
- **R6.2** No security-scoped bookmark is needed (App Sandbox grants the container Caches directly per ROADMAP's "Apple API spot-checks").
- **R6.3** Disk entries are PNG-encoded, bounded by a disk byte budget, LRU-evicted, and removed on invalidate/purge.

## R7 — Verification

- **R7.1** Unit test: cache hit on identical `(clipID, effectChainHash, time, renderSize)`.
- **R7.2** Unit test: miss when any single key field changes — clipID, effectChainHash, time, renderSize.
- **R7.3** Unit test: byte-budget eviction drops the least-recently-used entry first.
- **R7.4** Unit test: cache survives a composition rebuild but not an effect-chain edit (verified via `invalidate(clipID:)` clearing only matching entries).
- **R7.5** Unit test: render-size change clears non-matching entries via `invalidate(notMatchingRenderSize:)`.
- **R7.6** Unit test: `[Effect].renderCacheHash` differs across chains that differ in any way.
- **R7.7** Unit test: `RenderCacheKey` collapses equivalent CMTimes expressed in different timescales (Gemini review).
- **R7.8** Unit test: `EditorModel.updateSelectedClipCoalesced` invalidates the cache when `effects` changes (slider path) but leaves it alone for opacity-only edits (codex review P2).
- **R7.9** Unit test: evicted entries spill to disk, rehydrate on lookup, and purge removes the files.
- **R7.10** `xcodebuild` (Debug, macOS) green; no test count regression.
