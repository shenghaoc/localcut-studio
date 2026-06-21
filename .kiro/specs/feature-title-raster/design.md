# Design: Title Raster Path (P14 native equivalent)

> Status: **Proposed**. Infrastructure prerequisite for Phase 30 (animated captions) and Phase 38 (look packs).

## Goal

A reusable text-rasterisation path that draws a styled line of text once per (line, style, render-size) combination, hands the result back as a `CIImage` with a bounding box, and caches it across frames. Caption playback then becomes per-frame transform-and-composite, not per-frame text layout — preview stays realtime and export rests on the same path.

## Approach

1. **Core Text, not `CATextLayer`.** Per-glyph stroke + fill ordering matters for the styles Phase 30 ships (thick stroke around a colour fill, per-word recolour for karaoke). `CATextLayer` doesn't expose that ordering cleanly; `CTLine` does.
2. **One bitmap per (line, style, render size).** Render size determines the pixel grid and the wrap width; a project resize must invalidate. Style change must invalidate. Line text change must invalidate.
3. **LRU cache, bounded by entry count, not bytes.** Caption rasters at 1080p are ~tens of KB each (most of the canvas is transparent). A fixed entry count (default 128) is simpler than byte accounting.

## Types

```swift
struct TitleRasterRequest: Hashable {
    let lineID: UUID
    let styleHash: Int        // CaptionStyle.hash(into:) digest, Phase 30 owns the type
    let text: String          // included in the key so undo-typing invalidates
    let wordHighlightIndex: Int?  // nil ⇒ idle frame; non-nil ⇒ word-highlight pass
    let renderSize: CGSize
}

struct TitleRaster {
    let image: CIImage        // straight alpha, normalised to renderSize coordinates
    let boundingBox: CGRect   // in renderSize coordinates; centred horizontally by default
}

protocol TitleRasterer: AnyObject {
    func raster(for request: TitleRasterRequest,
                draw: (CGContext, CGSize) -> Void) -> TitleRaster
    func purge()
}
```

`draw` is a callback the *caller* supplies — Phase 30 closes over a `CaptionStyle` and writes the attributed-string-to-context code there. The rasterer only owns the bitmap allocation, the colour space, and the cache.

The phase-30 caller produces:
- `TitleRasterRequest` (with a stable `styleHash`)
- A `draw` closure that renders the text into the supplied `CGContext` at the supplied size

The rasterer then:
- Looks the request up in its cache
- On miss, allocates a `CGContext` (sRGB, premultiplied first BGRA, render-size sized), runs `draw`, wraps the result in a `CIImage`, and inserts the entry
- Returns the `TitleRaster`

## Cache

`OSAllocatedUnfairLock`-guarded `OrderedDictionary<TitleRasterRequest, TitleRaster>` — the front of the dictionary is most-recently-used. On insert past the entry cap, the back of the dictionary is dropped. `purge()` empties the cache; the editor calls it when render size or the entire caption track changes (a `lineID` change for any line is already covered by the cache key).

## Drawing context

- sRGB working space, matching the `EffectCompositor` (`workingColorSpace: sRGB`).
- Premultiplied BGRA — `CIImage(cvPixelBuffer:)` / `CIImage(cgImage:)` consume premultiplied data without surprises; the rest of the compositor is premultiplied.
- Y-axis flipped to match Core Image (text drawn through Core Text is laid out top-to-bottom; the resulting bitmap is then read by Core Image which expects bottom-up).
- The bitmap size equals the render size, so the rasterer's output composites at the render origin without further scaling — Phase 30's animation transforms operate on the same coordinate space as clip layers.

## Sub-pixel positioning

Sub-pixel offsets across animation frames cause shimmer. The rasterer renders to the integer pixel grid; *animation* transforms (translation, scale) are applied later by the compositor on a per-frame basis. Phase 30 picks easing-on-integer-positions to avoid the shimmer in slide / typewriter.

## Trade-offs

- **Caller draws, rasterer caches.** Lets Phase 30 own all styling decisions in one place. The rasterer stays small and reusable for future title text (lower-thirds, end-cards) without a styling explosion.
- **Entry-count cap over byte-budget cap.** Simpler; rasters are uniformly small at 1080p; a hard cap is more predictable than a soft byte budget that can swing with text length.
- **Render-size in the cache key.** Project aspect changes are rare but real; including the size in the key avoids a stale-bitmap class of bug.
- **Straight alpha bitmap returned as `CIImage`.** Core Image expects premultiplied. We render premultiplied straight into the context (`CGImageAlphaInfo.premultipliedFirst`), so what the caller sees as "straight alpha" is actually the framework-correct premultiplied path. No second pre-multiply needed.

## Risks

- A leaked draw closure could capture a `Project` reference, retaining the whole document via the cache. The rasterer documents this and stores the resulting `CIImage` only, never the closure.
- A font missing on the system shifts metrics; phase-30 presets reference fonts shipped with macOS and fall back loudly. The rasterer is font-agnostic by design.
- A pathological line (10k chars) would balloon the per-entry cost. The cache cap bounds total memory but the single-entry render is unbounded — Phase 30 truncates user text at the line level if needed.

## Non-goals

- Animating the *raster* itself (every animation is a per-frame transform applied by the compositor, evaluated by Phase 30).
- Vertical CJK text layout (deferred to a later phase).
- Subpixel font hinting toggles.
- Disk-backed cache (rebuilding from text is cheap; cold cache costs one layout per visible line).
