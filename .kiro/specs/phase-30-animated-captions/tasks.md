# Tasks: Phase 30 — Animated Caption Styles

> Status: **Implemented (v0.1.1 candidate)**. Prerequisites [`feature-keyframes`](../feature-keyframes/), [`feature-caption-tracks`](../feature-caption-tracks/), and [`feature-title-raster`](../feature-title-raster/) ship in the same change-set; [`feature-colour-grading`](../feature-colour-grading/) and [`feature-project-persistence`](../feature-project-persistence/) are on `main`.

## Model

- [x] **T1.1** Add `CaptionTrack`, `CaptionLine`, `WordTiming` to `Models.swift`; integrate with `Project`.
- [x] **T1.2** Add `CaptionStyle` value type with default + clamp; add line-level override and track default.
- [x] **T1.3** SRT/VTT importer producing `CaptionLine`s; unit tests on cue parsing edge cases.

## Engine

- [x] **T2.1** `CaptionRasterer` — Core Text attributed-string render with stroke + fill + shadow + glow + pill; output `CGImage` (wrapped as `CIImage`) + bounding box.
- [x] **T2.2** Idle frame cache keyed on `(lineID, styleHash, text, wordHighlightIndex?, renderSize)` with LRU eviction. Render size is part of the key because raster dimensions and text wrapping depend on the project canvas — a project aspect / resolution change must not surface a stale bitmap.
- [x] **T2.3** Animation evaluator — pop / bounce / slide / typewriter — returning transform + opacity + mask progress; deterministic.
- [x] **T2.4** Word-highlight pass — second attributed-string render that recolours the active word; cache per `(lineID, styleHash, wordIndex, renderSize)`.
- [x] **T2.5** Extend `EffectCompositor` to fetch active caption lines for the request time and composite rasters above clip layers, honouring track order.

## Presets

- [x] **T3.1** Define `CaptionPresetV1` JSON schema; codable round-trip + version migration scaffolding.
- [x] **T3.2** Author ≥10 built-in presets (Swift-bundled; not yet a separate `Resources/CaptionPresets/` directory because the synchronised root group only auto-includes Swift sources).
- [x] **T3.3** Import / export `.lccaption` files; sandbox-correct read and write.

## UI

- [x] **T4.1** Inspector "Captions" section: line list, preset picker, import / export buttons, per-line text field, add-line at playhead.
- [x] **T4.2** Coalesced updates: per-line text edits use `performCoalescedUndoable("Edit Caption", target: line.id, rebuild: .debounced)` so a typing burst against one line folds into a single undo step + one rebuild; discrete edits (add/remove/mute) use `performUndoable`.
- [x] **T4.3** Preset library accessible through the per-track preset picker plus `.lccaption` import / export.

## Verification

- [x] **T5.1** Snapshot tests for every built-in preset: render each preset's idle frame at 1280×720 and assert the rasteriser returns a non-empty raster whose bounding box sits inside the canvas. Stops short of pixel-golden PNG diffing — a full font-availability-matrix golden suite is left for a follow-up — but catches font lookup failures, layout breakage, and silent rasteriser fallbacks.
- [x] **T5.2** Smoke: hand-roll SRT → `CaptionImporter` → attach a preset → build composition through `CompositionBuilder` → assert the `AVVideoComposition` instruction covering the caption midpoint carries the caption render item with the expected text and style and forces tweening. Uses `AVAssetWriter` to generate a tiny solid-colour fixture clip in-process (same pattern as `TransitionsIntegrationTests`); no committed binary fixtures.
- [x] **T5.3** `xcodebuild` (Debug, macOS) green; no test count regression (129 tests passing, was 70 before Phase 30 work began — net +59 covering keyframes, caption tracks, title raster, animation evaluator, preset I/O, and every fix landed through five rounds of bot review).
