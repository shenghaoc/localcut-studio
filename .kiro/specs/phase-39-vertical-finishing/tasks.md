# Tasks: Phase 39 — Vertical and Platform Finishing

> Status: **Proposed**. Depends on the export-expansion spec + `feature-project-persistence`.

## Model

- [ ] **T1.1** Add `Project.aspect` and `Project.coverFrame` to `Models.swift`.
- [ ] **T1.2** Rebuild path: aspect changes regenerate the composition without resetting clip transforms.

## Safe zones

- [ ] **T2.1** Define `SafeZonesV1` JSON schema.
- [ ] **T2.2** Author and ship built-in zone files for the four launch platforms.
- [ ] **T2.3** CI step that validates each zone file against the schema.
- [ ] **T2.4** Preview overlay toggle that renders the active platform's polygon set.

## Cover picker

- [ ] **T3.1** Inspector "Cover" section: scrub picker, optional title overlay (basic Core Text now; Phase 30 styling when available).
- [ ] **T3.2** Cover export: PNG / JPEG / HEIC; lands alongside the video at export.
- [ ] **T3.3** Cover persisted in `ProjectDoc` + bundle.

## Export presets

- [ ] **T4.1** Define `PlatformPreset` model: resolution, fps, bitrate, container, loudness target.
- [ ] **T4.2** Ship presets for Douyin, Xiaohongshu, Shorts, Reels, TikTok, "16:9 YouTube".
- [ ] **T4.3** Capability validation against `AVAssetExportSession` + hardware encoder probe; explicit error on unmet capability.
- [ ] **T4.4** Loudness-target hook into Phase 36 (no-op until Phase 36 ships).

## Verification

- [ ] **T5.1** JSON Schema CI check.
- [ ] **T5.2** Snapshot tests of preview letterboxing at each aspect.
- [ ] **T5.3** Smoke: per-platform export → preset → cover included → no silent downgrade.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
