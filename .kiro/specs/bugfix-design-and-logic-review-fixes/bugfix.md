# Bugfix: Design and Logic Review Follow-up

> Status: **Complete**. Target branch: `fix/design-and-logic-issues`.

## Context

The design-and-logic audit branch added broad fixes across audio, timeline lookup,
render caching, accessibility, and architecture. A Codex review of the branch
found three remaining P1 regressions in the new behavior:

- Loudness gain could be applied by both `AVAudioMix` and the voice-cleanup DSP
  path, and repeat loudness measurement could measure audio that already had the
  previous gain applied.
- The new O(1) clip lookup index was refreshed through `scheduleRebuild()` but
  not through direct `rebuild()` or whole-state restore paths.
- `RenderCache` reinserted evicted frames into memory when disk spill failed,
  allowing RAM usage to exceed the configured budget indefinitely.

## Fix

- `CompositionBuilder` now applies loudness in the audio mix only for
  loudness-only compositions. When denoise/gate/compressor/limiter processing is
  active, the DSP path remains the single loudness owner. Loudness measurement
  builds opt out of audio-mix loudness so repeat analysis measures the source
  signal.
- `EditorModel.rebuild()` and `applyState(_:)` now rebuild the clip index after
  direct track replacement and undo/redo or document-style state restoration.
- `RenderCache` now drops evicted frames when disk spill fails. The frame can be
  regenerated, and the in-memory byte budget remains authoritative.

## Verification

- Added app regression tests for loudness ownership, measurement build gain
  exclusion, clip-index refresh, and disk-spill failure memory bounds.
- `swift test --package-path Packages/LocalCutCore` remains part of the gate for
  the shared settings comment update.
- macOS app `xcodebuild test` remains the required full gate for this PR.
