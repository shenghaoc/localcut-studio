# Design: Phase 30 — Animated Caption Styles (花字)

> Status: **Proposed**. Target tag: **v0.1.1**.

## Goal

Add a styling engine over caption tracks: stroke, fill, shadow, glow, per-line background pills, and enter/exit animations (pop, bounce, slide, typewriter) — rendered through the shared composition path so preview matches export. The caption data model gains an OPTIONAL per-word timing array; when present, karaoke-style word highlight activates. ASR comes later (Phase 29); manual captions must render full-line styles today.

## Prerequisites

- Caption track model + SRT/VTT sidecar I/O (not yet specced — derive a `CaptionTrack` of `CaptionLine { range: CMTimeRange, text: String, words: [WordTiming]? }` from the SRT/VTT importer, persisted via `feature-project-persistence`).
- Title raster path (not yet specced — a cached `CIImage` / Metal texture rasteriser that draws styled text once per line and reuses it across frames).
- Keyframes (not yet specced — `Keyframe<T>` and an evaluator) so style parameters (slide offset, scale, opacity, colour) animate.
- `feature-colour-grading`'s custom `AVVideoCompositing` is the integration point: caption rasters layer above clip layers.

## Approach

1. **Style model.** `CaptionStyle` value type — font (PostScript name + size), fill, stroke (colour + width), shadow (offset, blur), glow, background pill (colour, radius, padding), and an `enterAnimation` / `exitAnimation` enum with parameters. Each track or each line can hold a style; line-level overrides win.
2. **Preset library.** A versioned JSON file format (`CaptionPresetV1`) stored under `Library/Application Support/LocalCut Studio/CaptionPresets/`. ≥10 built-in presets ship in the app bundle and are read-only; user presets sit alongside, importable/exportable via `.fileImporter` / `NSSavePanel`. No network.
3. **Raster path.** `CaptionRasterer` produces a `CGImage` per line per state (idle vs animating). Idle frames cache by (line id, style hash). Animating frames render on demand. Text uses Core Text for proper attributed runs (stroke + fill + shadow per glyph run). Word-level highlight is a second pass with per-word attribute change, also cached.
4. **Animation.** Enter/exit are time-based curves driven by `(currentTime - lineStart) / enterDuration` etc. Pop = scale + opacity; bounce = damped spring; slide = translate from edge; typewriter = mask-progress 0→1 per character. All evaluated in the compositor at frame request time — deterministic and frame-accurate.
5. **Compositor integration.** Extend the `EffectCompositor` (from `feature-colour-grading`) so each frame request fetches the active `CaptionLine` set, asks `CaptionRasterer` for the appropriate raster, applies animation transforms, and composites above clip layers honouring track ordering.
6. **Sidecar export.** Burn-in remains the default (style is project-level). SRT/VTT sidecar export stays plain text — no style — and the export menu states this plainly.

## Trade-offs

- **Core Text vs `CATextLayer`**: Core Text gives us per-glyph control needed for stroke + fill + per-word highlight. `CATextLayer` is simpler but lossy on stroke-fill ordering.
- **Bake or live-evaluate animation**: live evaluation keeps timeline edits cheap and matches export exactly; pre-rendered video assets would be faster to preview but invalidate on every edit.
- **Preset format JSON vs binary plist**: JSON is human-shareable and easy to round-trip; the extra parsing cost is irrelevant at 10s-of-presets scale.

## Risks

- Font availability across macOS versions: presets must reference fonts shipped with the system; absent fonts fall back with a visible warning.
- Sub-pixel positioning during animation can cause shimmer; snap to pixel grid on integer time positions, ease only in between.
- Bundle round-trip must include any user font referenced as an embedded asset, or pin to a system font name with a fallback policy.

## Non-goals

- Speech recognition (Phase 29).
- Vertical CJK text layout.
- User-authored Metal kernels.
- A preset marketplace or any networked sharing.
