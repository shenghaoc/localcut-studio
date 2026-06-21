# Tasks: Phase 41 — Capture Engine

> Status: **Proposed**. Depends on the capability probe + diagnostics surface.

## Engine

- [ ] **T1.1** `ScreenCaptureSession` actor wrapping `SCStream` with display / window / app target.
- [ ] **T1.2** `WebcamCaptureSession` + `MicCaptureSession` over `AVCaptureSession`.
- [ ] **T1.3** `ContinuousWriter` per source — one `AVAssetWriter` for the whole session, real-time VideoToolbox properties, `movieFragmentInterval` set to the configured flush interval (default 2 s).
- [ ] **T1.4** Session `manifest.ndjson` writer — append-only event log; record kinds `header` / `epoch` / `source-ended` / `finalize`; forward-compatible parser ignores unknown kinds.
- [ ] **T1.5** Shared `CMClockGetHostTimeClock()` plumbing + `sessionStartHostTime` snapshot; landing offsets clip start times by `(capturedPTS − sessionStartHostTime)`.

## Storage + recovery

- [ ] **T2.1** First-recording UX picks the root folder via `NSOpenPanel` → security-scoped bookmark persisted in app settings. On every launch, resolve + `startAccessingSecurityScopedResource()` before the recovery scan; offer a "Choose recordings folder" command in Preferences for re-binding after a folder move.
- [ ] **T2.2** Capacity preflight + live monitor (warn at 10%, stop at 5%).
- [ ] **T2.3** Recovery scan on launch; surface partial sessions in the media bin.
- [ ] **T2.4** Recovered partial `.mov` per source loads as one composition source per track — no concatenation needed since fragments are within a single file.

## Capability gating

- [ ] **T3.1** Encoder-session budget check against the capability probe.
- [ ] **T3.2** Feature-detect ScreenCaptureKit system-audio availability per host.
- [ ] **T3.3** Surface "recording not supported on this Mac" on baseline tier.

## UI hooks

- [ ] **T4.1** Recorder modal (basic) — source picker, target picker; full UX in Phase 42.
- [ ] **T4.2** Live record indicator + storage countdown in the status bar.

## Verification

- [ ] **T5.1** 30-minute mocked-buffer test → bounded memory, single continuous file per source.
- [ ] **T5.2** Mocked-crash recovery test.
- [ ] **T5.3** Alignment test with two synthetic sources.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
