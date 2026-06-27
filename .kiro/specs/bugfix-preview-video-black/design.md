# Design: Bugfix — Preview video shows black / no video

> Status: **Complete**. Target tag: **v0.1.5-patch**.

## Problem

When a video clip is added to the timeline and playback is started, only audio is
heard — the preview canvas stays black. Export produces valid video, and
`AVAssetImageGenerator` renders frames correctly through the same
`videoComposition`, confirming the composition and custom compositor are sound.

## Root cause

`EffectCompositionInstruction.containsTweening` was computed dynamically: `true`
only when transitions or captions were present, `false` otherwise. When
`containsTweening` is `false`, AVFoundation may optimise by bypassing the custom
compositor and falling back to its default renderer. The default renderer does
not understand `EffectCompositionInstruction` (our custom instruction type), so
it produces no video output.

This affects AVPlayer preview specifically — `AVAssetImageGenerator` and
`AVAssetExportSession` both call the custom compositor unconditionally
(offline/synchronous paths), which is why export and image-generation tests
passed while preview was broken.

## Fix

Two changes in `EffectCompositor.swift`:

1. **`containsTweening` always `true`.** The `EffectCompositionInstruction`
   initialiser now unconditionally sets `containsTweening = true`, forcing
   AVFoundation to call our custom compositor for every frame regardless of
   whether transitions or captions are present.

2. **Added `cancelAllPendingVideoCompositionRequests()`.** An explicit no-op
   implementation ensures protocol conformance is complete on macOS 26.

## Verification

- `xcodebuild test` green (full suite).
- New `PreviewVideoDiagnosticsTests` validates composition structure, image
  generator rendering, and export output.
- The `containsTweening` change is the minimal fix — it does not alter rendering
  behaviour, only ensures the custom compositor is always driven.
