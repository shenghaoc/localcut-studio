# Tasks: Phase 30 — Animated Caption Styles

> Status: **Proposed**. Depends on caption track model, title raster path, keyframes, `feature-colour-grading`, `feature-project-persistence`.

## Model

- [ ] **T1.1** Add `CaptionTrack`, `CaptionLine`, `WordTiming` to `Models.swift`; integrate with `Project`.
- [ ] **T1.2** Add `CaptionStyle` value type with default + clamp; add line-level override and track default.
- [ ] **T1.3** SRT/VTT importer producing `CaptionLine`s; unit tests on cue parsing edge cases.

## Engine

- [ ] **T2.1** `CaptionRasterer` — Core Text attributed-string render with stroke + fill + shadow + glow + pill; output `CGImage` + bounding box.
- [ ] **T2.2** Idle frame cache keyed on `(lineId, styleHash)` with LRU eviction.
- [ ] **T2.3** Animation evaluator — pop / bounce / slide / typewriter — returning transform + opacity + mask progress; deterministic.
- [ ] **T2.4** Word-highlight pass — second attributed-string render that recolours the active word; cache per `(lineId, styleHash, wordIndex)`.
- [ ] **T2.5** Extend `EffectCompositor` to fetch active caption lines for the request time and composite rasters above clip layers, honouring track order.

## Presets

- [ ] **T3.1** Define `CaptionPresetV1` JSON schema; codable round-trip + version migration scaffolding.
- [ ] **T3.2** Author ≥10 built-in presets; bundle under `Resources/CaptionPresets/`.
- [ ] **T3.3** Import / export `.lccaption` files; sandbox-correct read and write.

## UI

- [ ] **T4.1** Inspector "Captions" section: line list, style picker, enter/exit animation pickers, durations.
- [ ] **T4.2** Coalesced updates on slider drags so preview stays scrubbable.
- [ ] **T4.3** Preset library panel with built-in + user sections; import + export buttons.

## Verification

- [ ] **T5.1** Snapshot tests for every built-in preset at a fixed time, project size, and font availability matrix.
- [ ] **T5.2** Smoke: SRT import → preset → scrub → export; exported frames match preview at sampled times.
- [ ] **T5.3** `xcodebuild` (Debug, macOS) green; no test count regression.
