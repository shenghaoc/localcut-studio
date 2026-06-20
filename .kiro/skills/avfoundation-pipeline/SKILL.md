---
name: avfoundation-pipeline
description: AVFoundation composition/export conventions for LocalCut Studio. Use when editing CompositionBuilder, the exporter, the custom compositor, or any CMTime/AVAsset code.
metadata:
  version: "1.0.0"
---

# AVFoundation Pipeline — LocalCut Studio

The editing core turns a `Project` into AVFoundation objects that drive preview and export from **one** build.

## Rules

1. **One build, two consumers** — `CompositionBuilder.build(project:)` returns a `BuiltComposition` (composition + optional `AVVideoComposition` + duration). Preview wraps it in `AVPlayerItem`; export feeds it to `AVAssetExportSession`. Never compute effects/transforms in only one path.
2. **`CMTime` everywhere** — all editing math uses `CMTime`/`CMTimeRange` at timescale `600`. Convert to `Double` seconds only at the UI boundary (pixels ↔ time).
3. **Async loading only** — `try await asset.load(.duration)`, `loadTracks(withMediaType:)`, `track.load(.naturalSize)`, `.preferredTransform`. Never the deprecated synchronous accessors.
4. **One composition track per project track** — clips on a track share a composition track (a layer). Insert with `insertTimeRange(_:of:at:)` using the clip's source range and timeline start.
5. **Video composition instructions are non-overlapping** — segment the timeline at every clip boundary; each interval emits one `AVMutableVideoCompositionInstruction` whose layer instructions cover the tracks visible in that interval. Topmost track's layer instruction goes **first** in the array.
6. **Transforms** — aspect-fit each source into `renderSize` after applying its `preferredTransform`, centered. Keep this in one helper (`fitTransform`) so preview and export agree.
7. **Effects live in a custom compositor** — colour grading and Core Image filters go in an `AVVideoCompositing` implementation set as `videoComposition.customVideoCompositorClass`, so both paths render identically. Don't use the `applyingCIFiltersWithHandler:` shortcut once multi-track compositing is in play (it flattens to a single source).
8. **Export** — use the modern async API: `try await session.export(to: url, as: .mov)`; observe progress with `for await state in session.states(updateInterval:)` and cancel the progress `Task` in a `defer`.

## Resource lifetime

- Generate thumbnails with a short-lived `AVAssetImageGenerator` (`appliesPreferredTrackTransform = true`, bounded `maximumSize`); don't keep one per clip.
- Balance `startAccessingSecurityScopedResource()` for imported URLs; persist via bookmarks in the document layer.
- Remove the `AVPlayer` periodic time observer in `deinit`; cancel owned `Task`s.

## Gotchas

- Empty timeline → return `nil` (no instructions = invalid video composition); the model then clears the player item.
- `videoComposition.frameDuration` must match `project.frameRate`; `renderSize` must match `project.renderSize`.
- A clip split must preserve `sourceStart + offset` on the right half so the cut is seamless.
