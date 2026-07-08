# Tasks: Design and Logic Review Follow-up

> Status: **Complete**.

## Implementation

- [x] **T1.1** Apply loudness gain through `AVAudioMix` only when no DSP insert
  requires the voice-cleanup processing path.
- [x] **T1.2** Keep DSP-active preview/export loudness inside
  `VoiceCleanupDSP`, preserving the denoise/gate/compressor -> loudness ->
  limiter ordering.
- [x] **T1.3** Build loudness-measurement compositions without existing
  audio-mix loudness gain.
- [x] **T2.1** Refresh `EditorModel`'s clip lookup index during explicit
  `rebuild()` calls.
- [x] **T2.2** Refresh the clip lookup index during `applyState(_:)` after
  restored track arrays are installed.
- [x] **T3.1** Keep `RenderCache` within the in-memory byte budget when disk
  spill fails by dropping evicted frames instead of reinserting them.

## Verification

- [x] **V1** Add app tests for loudness-only, DSP-active, and measurement-build
  loudness ownership.
- [x] **V2** Add app tests for `rebuild()` and `applyState(_:)` clip-index
  refresh.
- [x] **V3** Add an app test for failed disk spill preserving the memory budget.
- [x] **V4** Update PR #92 with the follow-up fixes and validation status.
