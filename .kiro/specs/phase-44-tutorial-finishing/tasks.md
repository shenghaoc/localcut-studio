# Tasks: Phase 44 — Tutorial Finishing

> Status: **Proposed**. Depends on Phase 30, Phase 43, markers spec, persistence.

## Silence detection

- [ ] **T1.1** Offline RMS-with-hysteresis pass on the selected audio track via vDSP.
- [ ] **T1.2** `ProposedCut` model + ordered list output; tuning parameters surfaced.
- [ ] **T1.3** Review modal: per-region apply / skip, scrubbable preview, single-transaction apply.

## Keystroke overlay

- [ ] **T2.1** `KeystrokeOverlayClip` kind reading a Phase 43 event log.
- [ ] **T2.2** Renderer (text + modifier chips); configurable font / position / fade.

## Chapter export

- [ ] **T3.1** YouTube chapter text writer + format linter (in CI).
- [ ] **T3.2** `AVAssetWriter` chapter-track integration for `.mov` / `.mp4` containers; fallback to sidecar otherwise.
- [ ] **T3.3** Manual verification checklist (VLC, QuickTime, YouTube).

## Caption preset

- [ ] **T4.1** Author the tutorial caption preset; ship under `Resources/CaptionPresets/`.

## Verification

- [ ] **T5.1** Determinism test on silence detection fixtures.
- [ ] **T5.2** YouTube linter in CI.
- [ ] **T5.3** Smoke: silence → review → apply → undo → re-apply → export with chapters.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
