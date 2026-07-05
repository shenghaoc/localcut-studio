# Verifying OTIO and EDL Interchange

This document provides manual verification checklists for the OpenTimelineIO (`.otio`) and CMX3600 EDL (`.edl`) export features.

## Kdenlive 25.04+ Manual Check

1. Export a project from LocalCut Studio as `.otio` (File ▸ Export Timeline (.otio)…).
2. Open Kdenlive 25.04 or later.
3. File ▸ Open File… and select the `.otio` file.
4. Verify:
   - All video tracks appear in the timeline.
   - Clip positions and durations match the LocalCut timeline.
   - Cross-dissolve transitions appear as Kdenlive transitions.
   - Markers appear in the marker track.
5. Known limitations:
   - Effects, transforms, and keyframes appear only under `metadata.localcut` and are ignored by Kdenlive.
   - Caption tracks are stored under `metadata.localcut.captionTracks` — Kdenlive does not read them.
   - Speed curves are stored under `metadata.localcut.speedCurve` — Kdenlive uses the average-adjusted `source_range`.

## DaVinci Resolve Manual Check

1. Export a project from LocalCut Studio as `.otio`.
2. Open DaVinci Resolve.
3. File ▸ Import ▸ Timeline… and select the `.otio` file.
4. Verify:
   - Clips appear on the correct tracks.
   - Source ranges are correct.
   - Transitions appear at cut points.
   - Markers are visible in the timeline.
5. Known limitations:
   - Resolve ignores `metadata.localcut` — effects, LUTs, and caption styling do not transfer.
   - Generator references (titles) appear as offline clips.
   - Missing references show as offline media with the original filename preserved.

## EDL Tool / Manual Check

1. Export a video track as `.edl` (File ▸ Export EDL (.edl)…).
2. Open the `.edl` file in a text editor and verify:
   - Header contains the project title.
   - For fractional rates (29.97, 23.976), a `* LOCALCUT: RATE` comment is present.
   - Event numbers are sequential (001, 002, …).
   - Reel names are uppercase alphanumeric, max 8 characters.
   - Record timecodes start at `01:00:00:00`.
   - Source timecodes match the clip's source range.
3. Import the `.edl` into DaVinci Resolve or an EDL-capable NLE:
   - Verify cuts appear at the correct timeline positions.
   - Verify source clips reference the correct media.

## What Should Round-Trip as Native OTIO

The following elements are standard OTIO and should be understood by any OTIO-compatible tool:

| Element | OTIO Schema |
|---------|-------------|
| Project timeline | `Timeline.1` |
| Track stack | `Stack.1` |
| Video/audio tracks | `Track.1` (kind `Video` / `Audio`) |
| Source clips | `Clip.2` with `ExternalReference.1` |
| Title/generator clips | `Clip.2` with `GeneratorReference.1` |
| Missing media | `Clip.2` with `MissingReference.1` |
| Gaps | `Gap.1` |
| Transitions | `Transition.1` (`SMPTE_Dissolve` for cross-dissolve) |
| Markers | `Marker.2` on the Stack |

## What Appears Only Under `metadata.localcut`

These LocalCut-specific features are preserved as opaque metadata:

- Effects chain (colour grade, skin smooth, grain, halation, vignette)
- LUT references (no texture data or security-scoped bookmark bytes)
- Transform keyframes (affine components)
- Volume envelopes and fades
- Speed curves (full curve + average-adjusted source range)
- Caption tracks and styling
- Layout tracks (Program Mode)
- Clip geometry (position offset, scale, mask)
- Clip opacity
- Media file fingerprints for bundle-generated `project.otio` files (SHA-256 on `ExternalReference.metadata.localcut.fingerprint`)
- Track mute state

## `otioconvert` Path for AAF / FCPXML

LocalCut Studio does not export AAF or FCPXML directly. Use the reference `otioconvert` tool:

```bash
pip install opentimelineio
otioconvert input.otio output.aaf
otioconvert input.otio output.fcpxml
```

This converts the `.otio` to AAF or FCPXML using the reference OTIO library. Note that `metadata.localcut` content will not be translated.

## Known Limitations

1. **No OTIO import.** Only export is supported. Import is a planned follow-up phase.
2. **No AAF/FCPXML in-app.** Use `otioconvert` as described above.
3. **Effects are not translated.** Effects, transforms, keyframes, and LUTs are preserved only as opaque metadata under `metadata.localcut`.
4. **Media is referenced, not embedded.** The `.otio` file contains target URLs, not media bytes. Media files must be accessible at the referenced paths.
5. **EDL is cuts-only.** The CMX3600 EDL contains only straight cuts. Transitions on the exported track are degraded to straight cuts with a warning.
6. **Audio events/dissolves omitted from EDL.** The EDL exports a single video track only. Audio events and audio dissolves are not included.
7. **Speed curves may not round-trip.** Non-uniform speed curves emit a warning; the `source_range` is adjusted to the average ramp ratio for foreign tools.
