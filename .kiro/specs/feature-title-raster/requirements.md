# Requirements: Title Raster Path

## R1 — Rasterer

- **R1.1** A `TitleRasterer` produces a `CIImage` + bounding box for a `(lineID, styleHash, text, wordHighlightIndex?, renderSize)` request.
- **R1.2** The bitmap is sRGB, premultiplied first BGRA, dimensioned to `renderSize`, with the text laid out in render-canvas coordinates.
- **R1.3** Layout uses Core Text (`CTLine` / `CTFramesetter`) so per-glyph stroke + fill ordering is preserved.
- **R1.4** The caller supplies the draw closure; the rasterer owns the bitmap, the colour space, and the cache.

## R2 — Cache

- **R2.1** The rasterer holds an LRU cache keyed exactly on `TitleRasterRequest`.
- **R2.2** Default capacity is 128 entries; new inserts evict the least-recently-used entry on overflow, and lookup touches are O(1).
- **R2.3** A `purge()` method empties the cache; the editor calls it on project render-size change and on track-level resets.
- **R2.4** Inserts and lookups are thread-safe (`OSAllocatedUnfairLock`).

## R3 — Determinism

- **R3.1** Identical requests with identical draw closures yield identical bitmaps across runs and processes (modulo OS font availability).
- **R3.2** No floating timestamp, random seed, or process-id input.

## R4 — Performance

- **R4.1** A 1080p single-line render completes in < 5 ms on Apple Silicon (M-series, common case); the rasterer does not block the main actor.
- **R4.2** Memory cost per cached entry is bounded by the render-size bitmap. The cache cap × bitmap-bytes is the worst-case footprint; document the math in `design.md`.

## R5 — Verification

- **R5.1** Unit tests: cache hit on identical request, cache miss on any field change, eviction at cap.
- **R5.2** Unit tests: bounding box is positive when the draw closure renders something; zero when the closure draws nothing.
- **R5.3** Unit tests: `purge()` empties the cache.
- **R5.4** `xcodebuild` (Debug, macOS) green; no test count regression.
