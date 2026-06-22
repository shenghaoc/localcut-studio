# Tasks: Render Cache

> Status: **Implemented**. Ships standalone; consumed by Phase 35 and Phase 37 once those land.

## Engine

- [x] **T1.1** Define `RenderCacheKey` (Hashable, Sendable) per the [design](./design.md#types). `CMTime` is normalised to a microsecond timescale so equivalent times in different timescales collapse to one key (Gemini review).
- [x] **T1.2** Add `[Effect].renderCacheHash` (Hasher digest over the chain, in order).
- [x] **T1.3** Implement `RenderCache`: `OSAllocatedUnfairLock`-guarded ordered dictionary; LRU touch on lookup; byte-budget eviction (sized off the stored image's `extent`, not the key's `renderSize` — Claude review); default budget 256 MiB.
- [x] **T1.4** `invalidate(clipID:)`, `invalidate(notMatchingRenderSize:)`, and `purge()` methods.
- [x] **T1.5** `RenderCache.cacheDirectoryURL` resolves the on-disk cache directory (`~/Library/Caches/com.shenghaoc.LocalCutStudio/RenderCache/`) for future disk-spill use.

## Compositor

- [x] **T2.1** Add `clipID: UUID` to `CompositorLayer`; thread `clip.id` through `CompositionBuilder.VideoSegment` so the layer carries it.
- [x] **T2.2** `EffectCompositor.applyEffectChain` consults `RenderCache.shared` before running the chain; on miss runs the chain, **materialises the result into a CGImage-backed `CIImage`** (so cache hits skip kernel evaluation, not just Swift filter-chain construction — codex review P1), and writes it back. No-op when `effects.isEmpty`. Skips the write when any effect failed to apply, so a transient LUT-load failure does not freeze the un-LUT'ed image (codex review P2).
- [x] **T2.3** Effect-chain edits in `EditorModel` invalidate the cache:
  - `selectedClipGrade` / `selectedClipSkinSmooth` setters
  - `updateSelectedClipSkinSmooth`, `resetClipColourEffects`, `resetClipSkinSmooth`, `importLUT`
  - **`updateSelectedClipCoalesced`** (the Inspector slider path) — diff-checks `effects` so opacity-only edits do not invalidate (codex review P2).
- [x] **T2.4** `EditorModel.setRenderSize` calls `RenderCache.shared.invalidate(notMatchingRenderSize:)` after applying the new size.
- [x] **T2.5** `EditorModel.releaseSession` calls `RenderCache.shared.purge()` on document swap.
- [x] **T2.6** The skin-mask debug visualisation (`layer.showSkinMask`) bypasses the cache so a normal preview after a mask-toggle isn't served the mask image.

## Verification

- [x] **V1** Unit test: identical request → cache hit; same `CIImage` instance returned.
- [x] **V2** Unit test: changing any one of `clipID`, `effectChainHash`, `time`, `renderSize` produces a miss.
- [x] **V3** Unit test: byte-budget eviction order — least-recently-used entries dropped first.
- [x] **V3.1** Unit test: byte cost reflects the stored image's `extent`, not the key's `renderSize` (Claude review).
- [x] **V4** Unit test: `invalidate(clipID:)` clears only matching entries; other clips' entries survive ("cache survives a composition rebuild but not an effect-chain edit").
- [x] **V5** Unit test: `invalidate(notMatchingRenderSize:)` drops entries that don't match the new size.
- [x] **V6** Unit test: `[Effect].renderCacheHash` differs across chains that differ in any way.
- [x] **V7** Unit test: `purge()` empties the cache.
- [x] **V8** Unit test: equivalent CMTimes expressed in different timescales collapse to one key (Gemini review).
- [x] **V9** Unit test: `updateSelectedClipCoalesced` invalidates the cache when `effects` changes but leaves it alone for opacity-only edits (codex review P2).
- [x] **V10** `xcodebuild` (Debug, macOS) green; no test count regression.

## ROADMAP

- [x] **T3.1** Move the **Render cache** row out of "Open infra" into the "Existing spec" table in [.kiro/specs/ROADMAP.md](../ROADMAP.md).
