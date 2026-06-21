# Requirements: Phase 39 — Vertical and Platform Finishing

## R1 — Aspect modes

- **R1.1** `Project.aspect` supports 16:9, 1:1, 9:16, 4:5, and a custom size.
- **R1.2** Changing aspect rebuilds the composition; existing clip transforms remain editable; the preview correctly letterboxes / pillarboxes.
- **R1.3** Aspect persists in `ProjectDoc` and survives bundle round-trip.

## R2 — Safe-zone overlays

- **R2.1** `SafeZonesV1` JSON schema defines per-platform occlusion polygons in normalised coordinates.
- **R2.2** Built-in zones ship for Douyin, Xiaohongshu, YouTube Shorts, Instagram Reels.
- **R2.3** A preview overlay toggle draws the zones above the clip; off by default.
- **R2.4** Safe-zone JSON validates against a published schema in CI.

## R3 — Cover (封面) picker

- **R3.1** Inspector "Cover" section: scrub to a frame, optional title overlay, export as PNG / JPEG / HEIC alongside the video.
- **R3.2** The chosen `coverTime` and optional title persist in `ProjectDoc`; the cover file ships in the bundle.
- **R3.3** Re-exporting with a different cover overwrites only the cover, never the video, unless the user explicitly re-exports both.

## R4 — Per-platform export presets

- **R4.1** Preset profiles for Douyin, Xiaohongshu, YouTube Shorts, Instagram Reels, TikTok, and "16:9 YouTube". Each carries resolution, fps, bitrate, container, and a loudness target.
- **R4.2** The selected preset feeds Phase 36 loudness normalisation when that phase is present; otherwise the loudness target is recorded but inert.
- **R4.3** Capability validation: an unsupported preset (HEVC unavailable, AV1 on Intel) yields an explicit error — never a silent downgrade.

## R5 — Verification

- **R5.1** JSON Schema validation of safe-zone files in CI.
- **R5.2** Snapshot tests of preview letterboxing at each aspect.
- **R5.3** Smoke: pick a preset for an aspect that mismatches the project → an explicit warning offers to switch project aspect.
- **R5.4** Bundle round-trip: cover, aspect, selected preset preserved.
- **R5.5** `xcodebuild` green; no test count regression.
