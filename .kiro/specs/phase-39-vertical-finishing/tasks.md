# Tasks: Phase 39 - Vertical and Platform Finishing

> Status: **In progress**. Depends on implemented `feature-export-queue`,
> `feature-project-persistence`, and `feature-project-bundles`. Phase 36 is a
> soft dependency for applying loudness targets.

## Canvas model

- [x] **T1.1** Add a project canvas/aspect value around `Project.renderSize`
  with built-ins for 16:9, 9:16, 1:1, 4:5, plus custom pixel size.
- [x] **T1.2** Add undoable `EditorModel` mutation(s) for changing aspect and
  render size. Coalesce committed changes so the composition rebuilds once per
  picker commit, not on every intermediate control update.
- [x] **T1.3** Extend `ProjectDocument` with aspect/cover fields using lenient
  decoding. Legacy documents infer aspect from `renderWidth`/`renderHeight`.
- [x] **T1.4** Preserve authored clip transforms, keyframes, effects,
  transitions, captions, markers, and audio state across aspect changes.

## Preview UI

- [x] **T2.1** Add an inspector canvas/aspect section that follows existing
  grouped `Form` styling and exposes built-in aspect choices plus custom size.
- [x] **T2.2** Add a preview geometry helper that maps normalized project-canvas
  coordinates into the visible AVPlayer preview rect, including letterboxing.
- [x] **T2.3** Show an explicit warning when a selected export preset's aspect
  differs from the project canvas, with "Switch Project Aspect" and "Queue
  Anyway" paths.
- [x] **T2.4** Add accessibility labels/help for any new icon-only aspect,
  warning, and safe-zone controls.

## Safe zones

- [x] **T3.1** Define `SafeZonesV1` Swift types and
  `Resources/SafeZones/safe-zones-v1.schema.json`.
- [x] **T3.2** Author built-in safe-zone JSON profiles for Douyin,
  Xiaohongshu, YouTube Shorts, Instagram Reels, and TikTok. Each profile
  includes source metadata and a `validatedAt` date.
- [x] **T3.3** Add CI/test validation for schema shape and semantic constraints
  (normalized coordinates, non-empty regions, unique ids, matching aspect).
- [x] **T3.4** Add a preview-only safe-zone overlay toggle and platform picker.
  The overlay is off by default and never enters `AVVideoComposition`.
- [ ] **T3.5** Surface malformed or missing safe-zone data through
  `statusMessage` without crashing preview or export.

## Cover picker

- [x] **T4.1** Add `CoverFrameDoc`/runtime cover state: selected `CMTime`,
  output format, optional static title, and optional bundle relative path.
- [x] **T4.2** Add an inspector "Cover" section with selected-frame preview,
  timeline/playhead binding, nudge controls, title fields, and format selector.
- [x] **T4.3** Implement cover generation from `BuiltComposition` using one
  `AVAssetImageGenerator` per request and the shared `videoComposition`.
- [x] **T4.4** Encode cover output as PNG/JPEG/HEIC through ImageIO, with
  explicit unsupported-format errors.
- [x] **T4.5** Capture an explicit user-confirmed cover output URL through
  `NSSavePanel`. Support "cover only" export without touching the video output.
- [ ] **T4.6** Extend `.lcbundle` layout/path validation for `covers/` and
  include generated cover assets on bundle save when present.

## Platform export profiles

- [x] **T5.1** Extend `ExportPreset` with optional platform metadata:
  platform id, safe-zone profile id, loudness target, and guidance source
  fields. Add explicit legacy decoding if synthesized Codable cannot preserve
  old queue jobs.
- [x] **T5.2** Add built-in profiles for Douyin, Xiaohongshu, YouTube Shorts,
  Instagram Reels, TikTok, and 16:9 YouTube using current platform guidance
  captured in source metadata.
- [ ] **T5.3** Extend capability validation for platform profiles: existing
  codec/container gate, HEVC availability, HEIC cover availability, and required
  output bookmarks.
- [x] **T5.4** Wire platform profile selection into `RenderQueueInspectorView`
  without duplicating the existing queue model or bypassing security-scoped
  output bookmarks.
- [x] **T5.5** Store Phase 36 loudness targets as inert metadata until Phase 36
  is implemented, then pass them into the normalization path.

## Verification

- [x] **T6.1** Unit tests: aspect-to-render-size mapping, custom size
  validation, legacy aspect inference, and `ProjectDocument` round-trip for
  canvas + cover fields.
- [x] **T6.2** Unit tests: aspect-fit/letterbox geometry for 16:9, 9:16, 1:1,
  and 4:5 canvases, including authored transforms that must survive aspect
  changes.
- [x] **T6.3** Unit/CI tests: every safe-zone JSON file validates against the
  schema and semantic validator.
- [x] **T6.4** Render queue tests: legacy `queue.json` decode, optional platform
  metadata round-trip, mismatched aspect warning state, and unsupported
  capability errors.
- [x] **T6.5** Cover tests: selected-time persistence and cover metadata
  round-trip. Unsupported-format and generated-image smoke are covered by the
  implementation path but still need a fixture-backed integration test.
- [ ] **T6.6** UI/accessibility smoke: aspect picker, safe-zone toggle/platform
  picker, cover controls, and platform preset rows are keyboard reachable and
  labelled.
- [x] **T6.7** `xcodebuild` (Debug, macOS) green; no test count regression.
