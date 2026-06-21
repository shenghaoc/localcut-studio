# Requirements: Phase 29 — On-Device Auto Captions

## R1 — ASR engine

- **R1.1** Tier A: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` is the default when supported on the host.
- **R1.2** Tier B: an optional Whisper Core ML model (Base default, Tiny lower-tier) downloads on demand with progress surfaced before any fetch.
- **R1.3** Model file integrity verified by SHA-256 against a versioned `ModelManifest.swift`; mismatched files are rejected.

## R2 — Audio extraction + windowing

- **R2.1** `AVAssetReader` decodes clip audio at 16 kHz mono Float32.
- **R2.2** A VAD pre-pass (energy + hysteresis) skips silence and tightens segment boundaries.
- **R2.3** Windowed inference uses ~30 s windows with overlap stride; window boundaries align to VAD output.

## R3 — Output model

- **R3.1** Output `[CaptionLine]` with `WordTiming` arrays — populates the Phase 30 `CaptionTrack`.
- **R3.2** Word timestamps are within ±150 ms of a reference transcript on fixture audio.
- **R3.3** Auto language detect per segment; user-selectable forced language overrides detection.

## R4 — Review-before-apply

- **R4.1** Modal surfaces proposed lines with per-line apply / skip and scrubbable preview.
- **R4.2** Apply commits as a single undoable transaction onto the existing `CaptionTrack`.
- **R4.3** Cancelling the modal leaves the project unchanged.

## R5 — Performance

- **R5.1** ≥ 2× realtime on M2 with the default model on a 10-minute 48 kHz track.
- **R5.2** Capacity-constrained hosts show an ETA and a "queue for later" option rather than hanging.
- **R5.3** Determinism in test mode (greedy decode) — identical inputs yield identical lines.

## R6 — Offline

- **R6.1** Tier A is available offline on supported hosts with no download.
- **R6.2** Tier B works fully offline after first model fetch; the cached model survives app restarts and macOS upgrades within a major version.
- **R6.3** Bundle round-trip preserves the caption proposals' review state and accepted lines.

## R7 — Verification

- **R7.1** Unit tests for word-timing tolerance against fixture transcripts.
- **R7.2** Smoke: select clip → transcribe → review → apply → export burn-in captions match preview.
- **R7.3** `xcodebuild` (Debug, macOS) green; no test count regression.
