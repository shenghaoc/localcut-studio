# Design: Phase 39 — Vertical and Platform Finishing

> Status: **Proposed**. Target tag: **v0.1.7**.

## Goal

Project aspect modes (9:16, 1:1, 4:5 alongside 16:9) with correct preview letterboxing; toggleable safe-zone overlays for Douyin, Xiaohongshu, Shorts, and Reels; a cover-frame (封面) picker; and per-platform export preset profiles extending the existing export.

## Prerequisites

- Export expansion (not yet specced) — preset model on top of `AVAssetExportSession` / `AVAssetWriter` with resolution + fps + bitrate + container options.
- `feature-project-persistence` (so the cover choice and per-platform settings ride in `ProjectDoc`).
- Phase 36 (voice cleanup) loudness targets for the per-platform LUFS hook (soft dep — preset can ship without it and gain a loudness target later).

## Approach

1. **Aspect modes.** `Project.aspect: enum { sixteenByNine, oneByOne, nineBySixteen, fourByFive }` (or a free `CGSize` for custom). Preview letterboxes correctly: the renderer canvas honours the project aspect; clips outside the canvas show as letterbox / pillarbox.
2. **Safe-zone overlay.** A versioned JSON schema `SafeZonesV1` defines per-platform polygons in normalised coordinates (UI occlusion areas — captions, profile, like / share). Ships under `Resources/SafeZones/<platform>.json` so we can update zones without an app update via a bundled refresh.
3. **Cover picker.** Inspector "Cover" section lets the user scrub to a frame, optionally compose a P14-style title above it, and export as PNG / JPEG / HEIC alongside the video. The chosen `coverTime: CMTime` and optional title overlay persist in `ProjectDoc`. The cover image is included in the bundle.
4. **Export presets.** Extend the export preset model with platform profiles: Douyin (vertical, H.264, –14 LUFS), Xiaohongshu (square, H.264 / HEVC, –14 LUFS), Shorts (vertical, H.264, –14 LUFS), Reels (vertical, H.264, –14 LUFS), TikTok variants, and a generic "16:9 YouTube". Each profile encodes resolution + fps + bitrate + container + loudness target.
5. **Capability gating.** Before kicking off an export, validate the chosen preset against `AVAssetExportSession` capability + the hardware encoder probe (HEVC available, AV1 not on Intel Macs etc.). On unmet capability, the export action shows an explicit error — never silently downgrades.
6. **Validation in CI.** Safe-zone JSON validates against a JSON Schema in CI so a typo in updated zones doesn't ship broken.

## Trade-offs

- Static safe-zone JSON vs. periodic remote refresh: we ship static, app-bundled JSON for now; a refresh URL is a v2 add and requires no UI change.
- Cover format choice: HEIC + PNG fallback gives both efficiency and broad compatibility.
- Per-platform aspect locking: changing aspect re-letterboxes existing clips and triggers a rebuild but does not modify the clip transforms — those remain editable.

## Risks

- Some platform aspect requirements change over time (Reels has shifted between 9:16 and 16:9 at different times); the JSON schema must be easy to amend.
- Cover composition with a styled title shares the Phase 30 caption raster path — Phase 39 ships before Phase 30 ideally, but a basic title (no animation) is achievable with Core Text directly. We ship the basic path now and integrate full Phase 30 styling once 30 lands.

## Non-goals

- Direct upload / publish APIs.
- Scheduled posting.
- Auto-translation of metadata for platforms.
