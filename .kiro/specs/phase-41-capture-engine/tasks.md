# Tasks: Phase 41 — Capture Engine

> Status: **Done**. All tasks implemented; verification tests pass.

## Engine

- [x] **T1.1** `CaptureCoordinator` actor that owns source sessions, writer lifetimes, capacity monitoring, manifest writes, stop sequencing, and recovery parsing; `EditorModel` only starts / stops and lands results on the main actor.
- [x] **T1.2** `ScreenCaptureSession` actor wrapping `SCStream` with display / window / app target.
- [x] **T1.3** `WebcamCaptureSession` + `MicCaptureSession` over `AVCaptureSession`.
- [x] **T1.4** `ContinuousWriter` per source — one `AVAssetWriter` for the whole session, real-time VideoToolbox properties, `movieFragmentInterval` set to the configured flush interval (default 2 s).
- [x] **T1.5** Bounded writer backpressure handling: no unbounded sample-buffer queues; sustained `isReadyForMoreMediaData == false` writes a `backpressure` manifest record and surfaces a visible warning / graceful stop.
- [x] **T1.6** Session `manifest.ndjson` writer — append-only event log; record kinds `header` / `epoch` / `source-ended` / `backpressure` / `finalize`; forward-compatible parser ignores unknown kinds and partial trailing lines.
- [x] **T1.7** Shared `CMClockGetHostTimeClock()` plumbing + `sessionStartHostTime` snapshot; landing offsets clip start times by `(capturedPTS − sessionStartHostTime)`.

## Storage + recovery

- [x] **T2.1** First-recording UX picks the root folder via `NSOpenPanel` → security-scoped bookmark persisted in app settings. On every launch, resolve + `startAccessingSecurityScopedResource()` before the recovery scan; offer a "Choose recordings folder" command in Preferences for re-binding after a folder move.
- [x] **T2.2** Capacity preflight + live monitor (warn at 10%, stop at 5%).
- [x] **T2.3** Recovery scan on launch; surface partial sessions in the media bin.
- [x] **T2.4** Recovered partial `.mov` per source loads as one composition source per track — no concatenation needed since fragments are within a single file.
- [x] **T2.5** Stale or missing recordings-root bookmark becomes a user-visible recovery state ("Choose recordings folder to recover sessions") instead of a silent empty scan.

## Capability gating

- [x] **T3.1** Encoder-session budget check against `Capabilities.tier(for: .simultaneousCaptureStreams(count:))`; baseline rejects recording, accelerated allows single / two-stream sessions, pro allows 3+ streams when the resolver permits.
- [x] **T3.2** Per-source resolution / fps preflight layered on top of the tier verdict; downshift or reject before capture starts rather than discovering overload mid-record.
- [x] **T3.3** Feature-detect ScreenCaptureKit system-audio availability per host.
- [x] **T3.4** Surface "recording not supported on this Mac" with the resolver's reason string on baseline tier.
- [x] **T3.5** Publish recorder live stats through the diagnostics/status surfaces: source count, duration, dropped/backpressured frames, disk remaining, and recovery state.

## UI hooks

- [x] **T4.1** Recorder modal (basic) — source picker, target picker; full UX in Phase 42.
- [x] **T4.2** Live record indicator + storage countdown in the status bar.
- [x] **T4.3** Permission failure states for screen recording, camera, microphone, and recordings folder access; each gives a concrete next action.
- [x] **T4.4** Clean stop lands captured sources into the current project as one undoable "Add Recording" action, one track per source; stopping/finalisation suppresses duplicate Stop taps while continuing to block New / Open / Close until landing is complete.

## Signing + privacy

- [x] **T5.1** Add camera + microphone sandbox entitlements only for this phase's concrete capture APIs.
- [x] **T5.2** Add `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` to the generated app Info.plist settings.
- [x] **T5.3** Add screen-recording preflight / request handling via the ScreenCaptureKit + TCC path and a clear denial state that points the user to System Settings.
- [x] **T5.4** Verify the signed Debug app prompts at runtime for the relevant permissions and surfaces denial cleanly.

## Verification

- [x] **T6.1** 30-minute mocked-buffer test → bounded memory, single continuous file per source.
- [x] **T6.2** Mocked-crash recovery test, including truncated manifest trailing line.
- [x] **T6.3** Manifest parser test for unknown record kinds (`scene-doc` / `scene-switch` future compatibility).
- [x] **T6.4** Alignment test with two synthetic sources.
- [x] **T6.5** Capability tests for baseline rejection and accelerated / pro stream-count gates.
- [x] **T6.6** `xcodebuild` (Debug, macOS) green.
