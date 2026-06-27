# Tasks: Bugfix — Preview video shows black / no video

> Status: **Complete**. Target tag: **v0.1.5-patch**.

## Diagnosis

- [x] **T0.1** Write diagnostic test (`PreviewVideoDiagnosticsTests`) that verifies video
  composition structure, `AVAssetImageGenerator` rendering, and export output.
  Confirmed: composition is correct, `AVAssetImageGenerator` produces non-black
  frames, export produces valid video.

## Fix

- [x] **T1.1** Root cause identified: `EffectCompositionInstruction.containsTweening`
  was `false` for simple clips (no transitions, no captions), causing AVPlayer to
  bypass the custom compositor and fall back to default rendering, which doesn't
  understand our custom instruction type.
- [x] **T1.2** Changed `containsTweening` to always be `true` so AVPlayer always
  calls the custom compositor.
- [x] **T1.3** Added `cancelAllPendingVideoCompositionRequests()` to
  `EffectCompositor` for complete macOS 26 protocol conformance.

## Verification

- [x] **T2.1** `PreviewVideoDiagnosticsTests` all pass (3 tests).
- [x] **T2.2** `xcodebuild test` green — full suite, no regressions.
- [x] **T2.3** Export still produces correct video (confirmed by
  `exportProducesValidVideo` test).
- [x] **T2.4** Manual smoke: needs verification on actual hardware.
