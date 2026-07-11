# LocalCut Studio User Guide

## WHIP publish

Open Program Mode before publishing. LocalCut streams the live program output:
the composited program video and the master-bus audio after live inserts.

In the Publish panel:

1. Choose the endpoint type.
2. Enter the WHIP endpoint URL.
3. Enter a stream key when the endpoint requires one.
4. Choose codec, video bitrate, audio bitrate, and best-effort keyframe interval.
5. Click Start publishing.

The status row shows connecting, live, reconnecting, failed, or ended state.
Stats show sent bytes, frames, bitrate, and round-trip time when WebRTC reports
them. Stop publishing sends WHIP DELETE to tear down the server-side resource.

The codec picker only exposes codecs supported by the current endpoint and local
encode probe. H.264 is the default for all endpoints; AV1 stays hidden until the
host and selected endpoint can both support it. WebRTC's macOS sender API does
not expose deterministic GOP control, so the keyframe interval is labelled
best-effort.

RTMP-only platforms are not sent to directly. Use a WHIP-to-RTMP gateway such as
MediaMTX when the destination does not offer WHIP ingest.

## Stream keys

Stream keys are session-only by default. LocalCut keeps the typed key in memory
so the publish session can start, but project documents and project bundles do
not include it.

When "Remember on this device" is enabled, LocalCut stores the key in the macOS
Keychain under the publish endpoint. Turning the option off removes the saved
key for that endpoint.

## WebRTC dependency

WHIP requires WebRTC peer connection support. macOS does not provide a native
framework that can push LocalCut's AVFoundation program feed into WebRTC, so the
app uses the pinned `webrtc-sdk/Specs` 125.6422.09 Swift package.

- Source: `webrtc-sdk/Specs` release 125.6422.09 (M125), the newest published
  release whose upstream SwiftPM manifest loads without modification. M137 uses
  `visionOS(.v2)` and M144 uses `visionOS(.v26)`, but both still declare tools
  5.9, so PackageDescription rejects them even with a newer installed compiler.
- License: BSD-3-Clause.
- Size: about 64 MB as the downloaded XCFramework zip.
- Worktrees: no setup is required. SwiftPM downloads the checksum-pinned
  package into its normal shared source/artifact cache.
- Audio input: LocalCut uses the package's public AVAudioEngine device-module
  delegate to connect an `AVAudioSourceNode` carrying master-bus PCM. No binary
  patch, copied private header, bootstrap script, symlink, or submodule is used.
- Build gate: guarded by `LOCALCUT_ENABLE_WEBRTC`, so custom builds can remove
  the dependency and compile the reduced publish UI state.

## Exporting OTIO and EDL

LocalCut Studio can export your timeline in two interchange formats for use in
other editing tools.

### Export Timeline (.otio)

OpenTimelineIO (OTIO) is an open-source timeline interchange format supported by
Kdenlive, DaVinci Resolve, and other NLEs.

1. Open your project.
2. File ▸ Export Timeline (.otio)… (or use the menu bar).
3. Choose a save location and click Save.

The `.otio` file contains:
- All video and audio tracks with clips and gaps.
- Transitions (cross-dissolve → `SMPTE_Dissolve`, others → `Custom_Transition`).
- Timeline markers.
- Media file references. When you save a `.lcbundle`, the automatic
  `project.otio` in the bundle also includes SHA-256 fingerprints for bundled
  assets.

LocalCut-specific features (effects, keyframes, caption styling, speed curves)
are preserved under `metadata.localcut` — foreign tools ignore this metadata.

### Export EDL (.edl)

CMX3600 EDL is a widely-supported cuts-only interchange format.

1. Open your project.
2. File ▸ Export EDL (.edl)….
3. If your project has multiple video tracks, choose which track to export.
4. Choose a save location and click Save.

The EDL exports a single video track with:
- Record timecode starting at `01:00:00:00`.
- Uppercase alphanumeric reel names (max 8 characters).
- Straight cuts only — transitions are degraded to cuts with a warning.
- Up to 999 events per list; larger tracks must be split before export.

For fractional frame rates (23.976, 29.97), a comment line notes the rate.

### Converting to AAF or FCPXML

LocalCut Studio does not export AAF or FCPXML directly. Use the reference
`otioconvert` tool from the OpenTimelineIO project:

```bash
pip install opentimelineio
otioconvert your_project.otio output.aaf
otioconvert your_project.otio output.fcpxml
```

### Warnings

Both exporters may produce warnings for:
- Clips that collapse to zero frames after frame-boundary snapping.
- Transitions without an adjacent clip pair.
- Missing source media references.
- Non-uniform speed curves (the average ratio is used for the emitted duration).

Warnings appear in the status bar after export.

### What External Tools May Ignore

- Effects, transforms, keyframes, LUTs, and fades.
- Caption tracks and styling.
- Volume envelopes.
- Speed curves (only the average-adjusted duration is emitted).
- Layout tracks (Program Mode).
- Media bytes (the `.otio` references files, it does not embed them).
