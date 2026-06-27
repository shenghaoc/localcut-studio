# Tasks: Preview Placeholder After Rebuild

> Status: **Complete**.

## Implementation

- [x] **T1.1** Add observed preview item availability to `EditorModel`.
- [x] **T1.2** Route preview item installation and clearing through
  `replacePreviewItem(with:)`.
- [x] **T1.3** Update `PreviewView` placeholder, transport enablement, and
  accessibility value checks to use `hasPreviewItem`.
- [x] **T1.4** Clear observed preview item state during new-project and session
  release flows.
- [x] **T1.5** Keep dynamic `containsTweening` behavior; do not force the custom
  compositor as a workaround.

## Verification

- [x] **V1** Add a Swift Testing regression for import -> Add -> rebuilt
  `AVPlayerItem` publishing `hasPreviewItem`.
- [x] **V2** Add preview composition smoke coverage for a generated H.264 video
  fixture.
- [x] **V3** Verify a plain clip interval keeps `containsTweening == false`.
- [x] **V4** Verify preview rendering through `AVAssetImageGenerator` produces a
  non-black frame.
- [x] **V5** Verify export produces a valid non-black video file.
- [x] **V6** Full macOS `xcodebuild test` suite passes.

## Pre-merge Checks

- [x] **M1** PR body names PR #55 as the regression source and distinguishes PR
  #48 as the earlier placeholder-shape change.
- [x] **M2** Live GitHub review threads are resolved.
- [x] **M3** GitHub CI is green.
- [x] **M4** HIG impact reviewed: no new visible controls or custom interaction
  patterns were added.
- [x] **M5** Module boundary reviewed: the fix stays in `EditorModel`,
  `PreviewRebuildCoordinator`, `DocumentController`, and `PreviewView`.
