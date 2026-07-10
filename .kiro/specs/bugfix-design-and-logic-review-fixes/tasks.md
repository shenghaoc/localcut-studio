# Tasks: Design and Logic Review Fixes

> Status: **Complete and verified**.

## Implementation

- [x] **T1.1** Apply loudness gain through `AVAudioMix` only when no DSP insert
  requires the voice-cleanup processing path.
- [x] **T1.2** Keep DSP-active preview/export loudness inside
  `VoiceCleanupDSP`, preserving the denoise/gate/compressor -> loudness ->
  limiter ordering.
- [x] **T1.3** Build loudness-measurement compositions without existing
  audio-mix loudness gain.
- [x] **T1.4** Rebuild loudness-only compositions whenever the applied gain
  value changes while remaining enabled.
- [x] **T1.5** Cancel stale scheduled DSP audio and reset mixer gain when
  switching between DSP-active, loudness-only, and dry preview routes.
- [x] **T2.1** Refresh `EditorModel`'s clip lookup index during explicit
  `rebuild()` calls.
- [x] **T2.2** Refresh the clip lookup index during `applyState(_:)` after
  restored track arrays are installed.
- [x] **T2.3** Validate indexed clip IDs and scan as a correctness fallback
  after direct track mutations shift cached offsets.
- [x] **T3.1** Keep `RenderCache` within the in-memory byte budget when disk
  spill fails by dropping evicted frames instead of reinserting them.
- [x] **T4.1** Keep beat-cut segment state unchanged when a zero-duration
  candidate is skipped.
- [x] **T4.2** Reject one-piece beat-cut results before timeline mutation,
  status success, or undo registration.
- [x] **T5.1** Keep Screencast Tools and Tutorial Finishing mounted for
  discoverability; gate individual actions instead of hiding whole sections.
- [x] **T5.2** Accept any audio-bearing timeline media, including video-track
  clips, as a silence-detection input.
- [x] **T6.1** Preserve selection/document invariants, overlay keyframe
  persistence, export cleanup, and user-visible failure reporting across the
  audited feature paths described in `bugfix.md`.
- [x] **T6.2** Clamp caption word ranges on both start and duration retimes.
- [x] **T6.3** Serialize `ProgramSessionTests`, whose cases share the
  process-wide one-session invariant, so the full target is deterministic.
- [x] **T6.4** Align nested task capture ownership at SwiftUI/AppKit edges and
  remove the unused auto-zoom duration value so the macOS target compiles
  without Swift warnings on the current toolchain.
- [x] **T6.5** Keep Xcode's local ad hoc signing enabled in CI so Gatekeeper
  permits the UI-test runner to bootstrap and the MediaMTX test host retains
  its localhost network entitlement.
- [x] **T6.6** Gate MediaMTX discovery with a script-owned marker so the
  required integration cases execute under Xcode 27 instead of skipping.
- [x] **T6.7** Align the MediaMTX readiness route, WHIP endpoint, and teardown
  path assertion with the pinned server and product defaults.

## Verification

- [x] **V1** Add app tests for loudness-only, DSP-active, and measurement-build
  loudness ownership.
- [x] **V2** Add app tests for `rebuild()` and `applyState(_:)` clip-index
  refresh.
- [x] **V3** Add an app test for failed disk spill preserving the memory budget.
- [x] **V4** Add app regressions for beat-cut no-op handling, active loudness
  gain rebuilds, stale index offsets, and audio-bearing video input.
- [x] **V5** Run `git diff --check`, `swift test --package-path
  Packages/LocalCutCore`, focused touched app tests, and the full macOS
  `xcodebuild test` suite successfully.
- [x] **V6** Update PR #92 metadata with the final diff, exact commands, review
  resolution, and live check state.
