# Tasks: Phase 44 — Tutorial Finishing

> Status: **Implemented**. Depends on Phase 30, Phase 43, markers spec, persistence.

## Silence detection

- [x] **T1.1** Offline RMS-with-hysteresis pass on the selected audio track via vDSP.
- [x] **T1.2** `ProposedCut` model + ordered list output; tuning parameters surfaced.
- [x] **T1.3** Review modal: per-region apply / skip, scrubbable preview, single-transaction apply.

## Keystroke overlay

- [x] **T2.1** `KeystrokeOverlayClip` kind reading a Phase 43 event log.
- [x] **T2.2** Renderer (text + modifier chips); configurable font / position / fade.

## Chapter export

- [x] **T3.1** YouTube chapter text writer + format linter (in CI).
- [x] **T3.2** `AVAssetWriter` chapter-track integration for `.mov` / `.mp4` containers; fallback to sidecar otherwise.
- [x] **T3.3** Manual verification checklist (VLC, QuickTime, YouTube) documented in `docs/chapter-export-verification.md`; player playback remains a manual environment check.

## Caption preset

- [x] **T4.1** Author the tutorial caption preset; ship under `Resources/CaptionPresets/`.

## Verification

- [x] **T5.1** Determinism test on synthetic silence detection fixtures.
- [x] **T5.2** YouTube chapter linter regression runs under the LocalCutCore package CI gate.
- [x] **T5.3** Smoke: silence → review → apply → undo → re-apply → export with chapters.
- [x] **T5.4** `xcodebuild` (Debug, macOS) green.
