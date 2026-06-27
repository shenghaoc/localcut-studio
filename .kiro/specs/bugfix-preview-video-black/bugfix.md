# Bugfix: Preview video shows black / no video

> Status: **In progress**. Target tag: **v0.1.5-patch**.

## Observed behaviour

Adding a video clip to the timeline and clicking play produces audio but no
video — the preview canvas remains black. Export produces valid video, and
`AVAssetImageGenerator` renders frames correctly through the same
`videoComposition`, confirming the composition and custom compositor are sound.

## Expected behaviour

Video frames render in the preview canvas during playback, matching what export
produces.

## Reproduction

1. Open the app (fresh project).
2. Import a video file (any format with H.264 video track).
3. Drag the clip onto the timeline.
4. Press play.
5. **Actual:** Audio plays; preview canvas is black.
6. **Expected:** Video plays in the preview canvas.

## Scope

- `EffectCompositor` — the custom `AVVideoCompositing` class.
- `AVVideoComposition.Configuration` — the macOS 26 API used to build the video
  composition.
- `PreviewRebuildCoordinator` / `PreviewPlayerView` — how the AVPlayerItem is
  delivered to AVPlayerView.

## Verification

- `xcodebuild test` green; new test covers `AVPlayerItemVideoOutput` frame
  extraction from the preview path.
- Manual smoke: import a video clip → play → video is visible in the canvas.
