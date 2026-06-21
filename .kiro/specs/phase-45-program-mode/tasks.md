# Tasks: Phase 45 — Program Mode

> Status: **Proposed**. Depends on Phase 41, `feature-colour-grading`, keyframes.

## Engine

- [ ] **T1.1** `EncoderBudget` actor with `acquire(.programIso)` + lease ledger.
- [ ] **T1.2** `ProgramCompositor` over existing Metal compositor; per-source `CVPixelBuffer` cache.
- [ ] **T1.3** `LiveComposeTap` per source; clone-before-encode discipline.
- [ ] **T1.4** `ProgramSession` orchestrator over the Phase 41 session model.

## Scene model

- [ ] **T2.1** `SceneDoc` + `SceneDefinition` + `SceneLayer` types; codable.
- [ ] **T2.2** `resolveSceneAt(scenes, sceneId, frames, stills, ...)` pure function.
- [ ] **T2.3** Hotkey conflict detector.
- [ ] **T2.4** Optional 200 ms eased transition implementation.

## Manifest

- [ ] **T3.1** Extend Phase 41 manifest with `scene-switch` record kind.
- [ ] **T3.2** Forward-compatible parser.

## Landing

- [ ] **T4.1** Layout track type + `LayoutClip` model.
- [ ] **T4.2** Stop → segment partition → `LayoutClip` array → new track.
- [ ] **T4.3** Single-transaction landing of ISO + layout tracks.

## UI

- [ ] **T5.1** `ProgramPanel` view: sources, scenes, hotkeys, start / stop, budget readout.
- [ ] **T5.2** Full-resolution program monitor sharing the existing preview output.

## Verification

- [ ] **T6.1** Unit test: scene-switch tick invariant.
- [ ] **T6.2** Budget-exhaustion test.
- [ ] **T6.3** Recovery test.
- [ ] **T6.4** Smoke: 2-cam + 1-screen + mic with 3 switches.
- [ ] **T6.5** `xcodebuild` (Debug, macOS) green.
