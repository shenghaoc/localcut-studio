# Requirements: Phase 39 - Vertical and Platform Finishing

## R1 - Project canvas and aspect modes

- **R1.1** The runtime model supports a project canvas profile for 16:9, 9:16,
  1:1, 4:5, and custom pixel sizes. `Project.renderSize` remains the
  authoritative render canvas consumed by `CompositionBuilder`; the aspect
  profile is the user-facing label and preset bridge.
- **R1.2** Changing the project aspect updates `Project.renderSize`, rebuilds
  the shared preview/export composition once per committed change, and does not
  reset clip transforms, keyframes, effects, captions, markers, transitions, or
  audio state.
- **R1.3** Preview and export use the same canvas math. Landscape media in a
  vertical/square project and vertical media in a landscape project render with
  deterministic aspect-fit placement on the black project canvas unless the
  user has authored a transform.
- **R1.4** Aspect settings persist through `ProjectDocument` and `.lcbundle`
  round-trip. Legacy documents with only `renderWidth`/`renderHeight` infer the
  nearest built-in aspect, falling back to custom without data loss.
- **R1.5** The inspector warns when the selected export preset's aspect differs
  from the project canvas and offers an explicit "Switch Project Aspect" action.
  The app never silently crops, stretches, or changes the project aspect at
  enqueue/export time.

## R2 - Safe-zone overlays

- **R2.1** A versioned `SafeZonesV1` JSON schema defines platform profiles in
  normalized canvas coordinates. Each profile records a platform id, display
  name, target aspect, source metadata (`sourceName`, optional `sourceURL`,
  `validatedAt`), and one or more occlusion polygons.
- **R2.2** Built-in launch profiles ship for Douyin, Xiaohongshu, YouTube
  Shorts, Instagram Reels, and TikTok. Profiles are data files under app
  resources, not hard-coded view geometry.
- **R2.3** The preview surface can toggle safe zones on/off and choose the
  active platform profile. The default state is off. The overlay draws above
  video/captions but never participates in preview/export pixels.
- **R2.4** Safe zones scale with the project canvas and preview letterboxing.
  Polygons remain visually aligned at 16:9, 9:16, 1:1, 4:5, and custom canvas
  sizes.
- **R2.5** Invalid safe-zone data is rejected with a developer-visible failure
  in tests/CI and a user-visible status message if a resource somehow fails at
  runtime. A malformed profile must not crash the app or prevent normal preview.

## R3 - Cover frame picker

- **R3.1** The inspector exposes a "Cover" section with a frame picker bound to
  timeline time, a preview of the selected frame, and an optional static title
  overlay. The first implementation uses a simple Core Graphics/Core Text draw
  path; Phase 30 animated caption styling can be integrated later.
- **R3.2** Cover frames are generated from the same `BuiltComposition` and
  `AVVideoComposition` used by preview/export so effects, transforms, captions,
  colour management, and aspect canvas placement match the rendered video.
- **R3.3** Cover export supports PNG, JPEG, and HEIC when the host encoder
  supports the requested format. Unsupported cover formats surface an explicit
  error and do not fall back silently.
- **R3.4** Exporting a cover sidecar is sandbox-correct. The cover exporter uses
  an explicit user-confirmed `NSSavePanel` URL for the cover file instead of
  assuming write access to a sibling path next to the video.
- **R3.5** `ProjectDocument` persists `coverFrame` data: selected time,
  optional title text/style, output format preference, and a bundle-relative
  generated asset path when a `.lcbundle` save includes the cover image under
  `covers/`.
- **R3.6** Re-exporting a cover can overwrite only the cover file. Re-exporting
  the video requires a separate explicit user action or render queue job.

## R4 - Platform export profiles

- **R4.1** Phase 39 extends the existing `ExportPreset`/`BuiltInExportPresets`
  model from `feature-export-queue`; it does not introduce a parallel preset
  type for platform finishing.
- **R4.2** Built-in platform profiles ship for Douyin, Xiaohongshu, YouTube
  Shorts, Instagram Reels, TikTok, and 16:9 YouTube. Each profile carries
  platform id, display name, aspect, target size, fps policy, bitrate bracket,
  container, codec, optional loudness target, default safe-zone profile id, and
  source metadata for the platform guidance used to author it.
- **R4.3** The render queue persists any new optional preset metadata
  losslessly. Existing `queue.json` jobs created before Phase 39 decode with
  defaults and remain runnable.
- **R4.4** Capability validation happens before enqueue and again before
  execution. Unsupported codec/container/format combinations, unavailable HEVC,
  unsupported HEIC cover export, or missing output bookmarks produce explicit
  errors; the app never silently downgrades a platform profile.
- **R4.5** If Phase 36 loudness normalization is present, the platform profile's
  loudness target feeds that path. Before Phase 36 lands, the target is stored
  and displayed as inert metadata.

## R5 - Verification

- **R5.1** Unit tests cover aspect-profile to render-size mapping, legacy
  document inference, and `ProjectDocument` round-trip for aspect and cover
  data.
- **R5.2** Composition/geometry tests cover aspect-fit placement and
  letterboxing for 16:9, 9:16, 1:1, and 4:5 canvases without losing authored
  clip transforms.
- **R5.3** Safe-zone JSON files validate against the checked-in schema in CI,
  and semantic tests reject out-of-range normalized coordinates, empty polygon
  sets, duplicate ids, and aspect/profile mismatches.
- **R5.4** Render queue tests cover mismatched project/preset aspect warnings,
  optional Phase 39 preset metadata round-trip, unsupported capability errors,
  and legacy queue decoding.
- **R5.5** Cover tests cover selected-time persistence, cover metadata
  round-trip, unsupported-format guard behavior, valid-frame snapping, generated
  image smoke, and `.lcbundle` cover asset writes including stale-format cleanup.
- **R5.6** UI/accessibility smoke covers the aspect picker, safe-zone toggle,
  platform profile selector, cover controls, and icon-only controls. New
  controls have accessibility labels and keyboard-reachable actions.
- **R5.7** `xcodebuild` (Debug, macOS) compiles cleanly and the test count does
  not regress.
