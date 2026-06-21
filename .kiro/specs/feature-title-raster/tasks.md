# Tasks: Title Raster Path

> Status: **Implemented**. Ships with Phase 30.

## Engine

- [x] **T1.1** Define `TitleRasterRequest` (Hashable) and `TitleRaster` types per the [design](./design.md#types).
- [x] **T1.2** Implement `TitleRasterer` concrete class: sRGB premultiplied-first BGRA `CGContext`, `CIImage` wrapping, premultiplied-correct alpha.
- [x] **T1.3** LRU cache backed by an ordered dictionary under `OSAllocatedUnfairLock`; cap = 128 entries; LRU touch on lookup.
- [x] **T1.4** `purge()` empties the cache; document call sites in the editor (render-size change, full caption-track reset).

## Verification

- [x] **T2.1** Unit test: identical request → cache hit; same `CIImage` instance returned.
- [x] **T2.2** Unit test: changing any one of `lineID`, `styleHash`, `text`, `wordHighlightIndex`, `renderSize` produces a fresh raster.
- [x] **T2.3** Unit test: inserting beyond the cap evicts the least-recently-used entry.
- [x] **T2.4** Unit test: `purge()` empties the cache (next request is a miss).
- [ ] **T2.5** Unit test: bounding box is positive for a closure that draws a glyph; zero for an empty closure.
- [x] **T2.6** `xcodebuild` (Debug, macOS) green; no test count regression.
