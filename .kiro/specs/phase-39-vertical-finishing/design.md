# Design: Phase 39 - Vertical and Platform Finishing

> Status: **Completed**. Target tag: **v0.1.7**.

## Goal

Add vertical-first finishing without splitting the render path: project canvas
aspect modes, preview-only safe-zone overlays, a cover-frame picker, and
platform export profiles built on the existing render queue. The user should be
able to turn a normal edit into a 9:16, 1:1, 4:5, or 16:9 deliverable, verify
that captions and subjects avoid platform chrome, pick a cover, and queue the
right output recipe without leaving the native macOS workflow.

## Prerequisites

- `feature-export-queue` is implemented and already owns `ExportPreset`,
  `ExportAspect`, `BuiltInExportPresets`, output bookmarks, and serial render
  jobs.
- `feature-project-persistence` and `feature-project-bundles` are implemented,
  so Phase 39 can extend `ProjectDocument` and bundle layout rather than define
  a new persistence path.
- Phase 36 is a soft dependency only for loudness normalization. Platform LUFS
  targets can be stored and displayed before the DSP path exists.

## Data model

`Project.renderSize` remains the render truth because `CompositionBuilder`
already consumes it directly for `AVMutableVideoComposition.renderSize`.
Phase 39 adds an aspect profile around that value instead of replacing it:

```swift
nonisolated enum ProjectAspect: String, Codable, Sendable, CaseIterable {
    case widescreen16x9
    case vertical9x16
    case square1x1
    case portrait4x5
    case custom
}

nonisolated struct ProjectCanvas: Codable, Hashable, Sendable {
    var aspect: ProjectAspect
    var renderSize: ExportSize
}
```

The runtime `Project` grows `canvas: ProjectCanvas` or equivalent computed
state while keeping `renderSize` available for existing code. Legacy documents
decode by looking at `renderWidth/renderHeight`: exact or near-exact ratios map
to built-ins, otherwise `custom`.

Cover state is small, document-owned metadata:

```swift
nonisolated struct CoverFrameDoc: Codable, Hashable, Sendable {
    var time: CMTimeCode
    var format: CoverFormat
    var title: CoverTitleDoc?
    var bundleRelativePath: String?
}
```

`bundleRelativePath` records the generated cover asset path when a `.lcbundle`
save includes a cover image under `covers/`. Explicit sidecar cover exports
still use a user-confirmed save-panel URL.

## Aspect modes

The aspect picker lives in the inspector's project/render settings, near the
existing render queue controls. Choosing a built-in aspect updates
`Project.renderSize` using stable defaults:

| Aspect | Default canvas |
| --- | --- |
| 16:9 | 1920 x 1080 |
| 9:16 | 1080 x 1920 |
| 1:1 | 1080 x 1080 |
| 4:5 | 1080 x 1350 |

Custom size exposes width/height fields with validation (positive finite
values, sensible maximum bounded by capability tier). A change is an undoable
project mutation and triggers one rebuild after commit. Clip transforms,
keyframes, opacity, effects, captions, transitions, markers, and audio
automation stay authored exactly as they were; the new canvas only changes how
the shared composition maps layers into output pixels.

The preview remains a black AVPlayer-backed surface. Letterbox/pillarbox areas
belong to the project canvas, not to burned-in padding added around the exported
file. The same `BuiltComposition.videoComposition` feeds preview and export,
so a vertical export and a vertical preview cannot drift.

## Safe zones

Safe zones are resource data, not Swift view constants. The resource layout is:

```text
Resources/SafeZones/
  safe-zones-v1.schema.json
  douyin.json
  xiaohongshu-square.json
  xiaohongshu-portrait.json
  youtube-shorts.json
  instagram-reels.json
  tiktok.json
```

Each profile is normalized to the project canvas:

```json
{
  "schemaVersion": 1,
  "platformID": "tiktok",
  "displayName": "TikTok",
  "aspect": "vertical9x16",
  "sourceName": "TikTok Business Help Center",
  "sourceURL": "https://...",
  "validatedAt": "2026-06-25",
  "regions": [
    {
      "id": "right-actions",
      "kind": "occlusion",
      "points": [
        { "x": 0.86, "y": 0.52 },
        { "x": 0.98, "y": 0.52 },
        { "x": 0.98, "y": 0.92 },
        { "x": 0.86, "y": 0.92 }
      ]
    }
  ]
}
```

`sourceURL` is optional because not every platform publishes stable organic-post
geometry, but `sourceName` and `validatedAt` are required. That makes the
volatility explicit: platform chrome changes are data updates, not code
rewrites. CI validates both JSON Schema shape and semantic constraints such as
normalized coordinates in `0...1`, non-empty polygon lists, unique ids, and
aspect/profile consistency.

Rendering is preview-only. A SwiftUI/Canvas overlay sits above `PreviewView`
inside the same letterboxed geometry, clips to the visible project canvas, and
respects the user's selected safe-zone profile. It is disabled by default and
never becomes part of `AVVideoComposition`.

## Cover picker

The inspector gains a grouped "Cover" section:

- time picker bound to the timeline/playhead, with nudge controls;
- generated still preview;
- optional static title text and placement;
- output format selector (PNG, JPEG, HEIC when available);
- "Export Cover..." action.

Frame generation uses the built composition:

1. Build or reuse the current `BuiltComposition`.
2. Create one `AVAssetImageGenerator` for the composition batch.
3. Assign the same `videoComposition` used for preview/export.
4. Request the selected `CMTime`.
5. Draw the optional static title into the resulting image with Core
   Graphics/Core Text.
6. Encode with ImageIO/UniformTypeIdentifiers to PNG, JPEG, or HEIC.

That path keeps cover pixels aligned with effects, colour management, captions,
transforms, and aspect canvas placement. The generator is one-per-request, not
one-per-frame in a hot loop.

Sandboxing matters for sidecars. A video output bookmark does not imply write
access to arbitrary sibling files forever, so Phase 39's cover export opens an
explicit `NSSavePanel` for the cover file. The UI can default the cover filename
beside the video, but the user still grants that exact URL before the app writes
it. Bundle saves generate a cover asset under `.lcbundle/covers/` when
`coverFrame` is present; a cover-generation failure is surfaced as a save
warning and does not corrupt the bundle.

## Platform export profiles

Phase 39 extends the existing export preset model instead of creating a
parallel `PlatformPreset`. The additive metadata is optional so old
`queue.json` entries keep decoding:

```swift
nonisolated struct PlatformExportMetadata: Codable, Hashable, Sendable {
    var platformID: String           // "youtube-shorts", "tiktok", ...
    var safeZoneProfileID: String?
    var loudnessTargetLUFS: Double?
    var guidanceSourceName: String?
    var guidanceSourceURL: String?
    var guidanceValidatedAt: String? // ISO yyyy-mm-dd
}

nonisolated struct ExportPreset: Codable, Hashable, Sendable, Identifiable {
    // Existing Phase 17 / 24 fields stay unchanged.
    var platformMetadata: PlatformExportMetadata?
}
```

If synthesized Codable is no longer enough once defaults are needed, Phase 39
adds an explicit decoder that treats missing fields as `nil` and preserves
legacy jobs. `BuiltInExportPresets.all` grows the platform profiles:

| Profile | Aspect | Baseline |
| --- | --- | --- |
| Douyin | 9:16 | H.264 MP4, 1080 x 1920, AAC |
| Xiaohongshu | 1:1 and 4:5 variants | H.264/HEVC MP4, AAC |
| YouTube Shorts | 9:16 | H.264 MP4, 1080 x 1920, AAC |
| Instagram Reels | 9:16 | H.264 MP4, 1080 x 1920, AAC |
| TikTok | 9:16 | H.264 MP4, 1080 x 1920, AAC |
| YouTube 16:9 | 16:9 | Existing YouTube preset family |

Exact bitrate and safe-zone geometry are intentionally data-authored with
source metadata because platform guidance changes. The implementation pass must
refresh those values from current platform guidance before checking off the
safe-zone/preset tasks.

When a user queues a preset whose `aspect` differs from the project canvas, the
inspector shows a warning with two explicit options: switch the project aspect
and rebuild, or queue anyway with the current canvas. There is no implicit
stretch/crop/downgrade.

Capability validation reuses the export queue's existing
`ExportPreset.isSupportedCombination(container:codec:)` gate, then adds host
checks for HEVC and cover HEIC availability. Failed validation blocks enqueue
or marks the job failed before encoding starts, with `statusMessage` and queue
row errors that explain the unsupported feature.

## Trade-offs

- **Project canvas around `renderSize`, not a new render abstraction.** This
  keeps `CompositionBuilder` stable and avoids a second source of truth.
- **Static bundled platform data.** Remote updates would require networking,
  signing, cache invalidation, and trust policy. Phase 39 ships offline data
  with source metadata; updating zones is a normal app update.
- **Basic cover title first.** Full Phase 30 animated caption styling is out of
  scope. A static title covers the common thumbnail use case without coupling
  this phase to the caption animation stack.
- **Explicit cover save panel.** Asking for cover output access is slightly more
  ceremony, but it keeps sandbox behavior correct and reviewable without
  expanding the render queue job shape in this pass.

## Risks

- Platform safe zones are approximations and can drift. The spec mitigates this
  with source metadata, schema validation, and data-only updates, but the UI
  must present zones as guidance rather than a guarantee.
- Aspect changes can expose assumptions in transform/keyframe math. Tests must
  cover authored transforms surviving canvas changes, not only default-fit
  clips.
- Cover generation from `AVAssetImageGenerator` can be expensive on long or
  effect-heavy projects. Generation runs as an explicit async action with
  progress/status feedback, not on every playhead tick.
- Extending `ExportPreset` touches persisted queue jobs. Legacy decoding and
  current-job round-trips need tests before merge.

## Non-goals

- Direct upload/publish APIs.
- Scheduled posting or account integration.
- Remote platform-data refresh.
- Automatic subject-aware reframing. Phase 33 owns smart reframe.
- Burning safe-zone guides into exports.
