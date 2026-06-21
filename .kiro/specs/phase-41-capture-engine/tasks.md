# Tasks: Phase 41 — Capture Engine

> Status: **Proposed**. Depends on the capability probe + diagnostics surface.

## Engine

- [ ] **T1.1** `ScreenCaptureSession` actor wrapping `SCStream` with display / window / app target.
- [ ] **T1.2** `WebcamCaptureSession` + `MicCaptureSession` over `AVCaptureSession`.
- [ ] **T1.3** `ChunkedWriter` per source — `AVAssetWriter` with real-time VideoToolbox properties.
- [ ] **T1.4** Chunk rotation (default 30 s) with atomic close / open.
- [ ] **T1.5** Session `manifest.json` writer; "stopped" marker on clean shutdown.
- [ ] **T1.6** Shared `CMClock` plumbing across all writers for alignment.

## Storage + recovery

- [ ] **T2.1** Sandbox bookmark to `~/Movies/LocalCut Recordings/`; create per-session UUID directory.
- [ ] **T2.2** Capacity preflight + live monitor (warn at 10%, stop at 5%).
- [ ] **T2.3** Recovery scan on launch; surface partial sessions in the media bin.
- [ ] **T2.4** Concatenate recovered chunks into one composition source per track (lossless, no re-encode).

## Capability gating

- [ ] **T3.1** Encoder-session budget check against the capability probe.
- [ ] **T3.2** Feature-detect ScreenCaptureKit system-audio availability per host.
- [ ] **T3.3** Surface "recording not supported on this Mac" on baseline tier.

## UI hooks

- [ ] **T4.1** Recorder modal (basic) — source picker, target picker; full UX in Phase 42.
- [ ] **T4.2** Live record indicator + storage countdown in the status bar.

## Verification

- [ ] **T5.1** Mocked-chunk 30-minute test → bounded memory.
- [ ] **T5.2** Mocked-crash recovery test.
- [ ] **T5.3** Alignment test with two synthetic sources.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
