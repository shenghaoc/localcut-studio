# Tasks: Phase 45 — Program Mode

> Status: **Draft implementation**. Depends on Phase 41, `feature-colour-grading`, keyframes.
> `swift test --package-path Packages/LocalCutCore`,
> `xcodebuild -quiet -scheme "LocalCut Studio" -destination "platform=macOS" build`,
> and `xcodebuild -quiet -scheme "LocalCut Studio" -destination "platform=macOS" build-for-testing`
> pass locally. `xcodebuild test` still hangs in this environment on
> pre-Phase-45 tests too and is tracked as pre-existing infrastructure, not a
> Phase 45 regression.

## Engine

- [x] **T1.1** `EncoderBudget` actor with `acquire(.programIso)` + lease ledger.
- [x] **T1.2** `ProgramCompositor` over existing Metal compositor; per-source `CVPixelBuffer` cache.
- [x] **T1.3** `LiveComposeTap` per source; clone-before-encode discipline.
- [x] **T1.4** `ProgramSession` orchestrator over the Phase 41 session model.

## Scene model

- [x] **T2.1** `SceneDoc` + `SceneDefinition` + `SceneLayer` types; codable.
- [x] **T2.2** `resolveSceneAt(scenes, sceneId, frames, stills, ...)` pure function.
- [x] **T2.3** Hotkey conflict detector.
- [x] **T2.4** Optional 200 ms eased transition implementation.

## Manifest

- [x] **T3.1** Extend Phase 41 manifest with `scene-switch` record kind.
- [x] **T3.2** Forward-compatible parser.

## Landing

- [x] **T4.1** Layout track type + `LayoutClip` model.
- [x] **T4.2** Stop -> segment partition -> `LayoutClip` array -> new track.
- [x] **T4.3** Single-transaction landing of ISO + layout tracks.
  - Layout tracks are now consumed by `CompositionBuilder`: scene-layer
    transforms override ISO track transforms during layout clip time ranges,
    scene colour layers become synthetic compositor units for export, and
    colour-only layout spans use the existing filler source so AVFoundation
    schedules the compositor. `MediaItem.captureSourceID` bridges scene-layer
    source refs to MediaItem IDs.

## UI

- [x] **T5.1** `ProgramPanel` view: sources (with per-source enable/disable toggles),
  scenes, hotkeys (wired to live scene switching via `onKeyPress`), start / stop,
  budget readout (reflects only enabled sources), shared `EncoderBudget`.
- [ ] **T5.2** Full-resolution program monitor sharing the existing preview output.
  - Draft gap: the panel is now reachable and supports persisted scene editing,
    but the monitor remains the existing preview surface rather than a dedicated
    Program Mode monitor.

## Verification

- [x] **T6.1** Unit test: scene-switch tick invariant.
- [x] **T6.2** Budget-exhaustion test.
- [x] **T6.3** Recovery test.
- [ ] **T6.4** Smoke: 2-cam + 1-screen + mic with 3 switches.
  - Requires physical capture hardware. Mocked coverage lives in
    `ProgramSessionTests` and `ProgramLandingTests`.
- [ ] **T6.5** `xcodebuild` (Debug, macOS) green.
  - `xcodebuild build` and `xcodebuild build-for-testing` pass. `xcodebuild test` runner hangs in this
    environment on pre-Phase-45 tests too; do not count it as a Phase 45
    regression without a separate infrastructure fix.
