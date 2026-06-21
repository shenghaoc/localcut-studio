# Requirements: Phase 29 — On-Device Auto Captions

## R1 — ASR engine

- **R1.1** `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` is the engine.
- **R1.2** When the host doesn't support on-device recognition (`requiresOnDeviceRecognition` returns `false`), the feature is hidden — no cloud fallback, no degraded path.

## R2 — Audio extraction + windowing

- **R2.1** `AVAssetReader` decodes clip audio in the format Speech expects.
- **R2.2** A VAD pre-pass (energy + hysteresis) skips silence and tightens segment boundaries.
- **R2.3** Windowed recognition uses overlap stride; window boundaries align to VAD output.

## R3 — Output model

- **R3.1** Output `[CaptionLine]` with `WordTiming` arrays at segment granularity — populates the Phase 30 `CaptionTrack`.
- **R3.2** Auto language detect per segment via `NLLanguageRecognizer`; user-selectable forced language overrides detection.

## R4 — Review-before-apply

- **R4.1** Modal surfaces proposed lines with per-line apply / skip and scrubbable preview.
- **R4.2** Apply commits as a single undoable transaction onto the existing `CaptionTrack`.
- **R4.3** Cancelling the modal leaves the project unchanged.

## R5 — Performance

- **R5.1** The UI remains interactive throughout (transcription runs on a background actor).
- **R5.2** Capacity-constrained hosts surface progress + cancel rather than blocking.

## R6 — Offline

- **R6.1** Works offline on every host where `SFSpeechRecognizer` reports on-device availability.
- **R6.2** No network calls.
- **R6.3** Bundle round-trip preserves the caption proposals' review state and accepted lines.

## R7 — Verification

- **R7.1** Smoke: select clip → transcribe → review → apply → export burn-in captions match preview.
- **R7.2** Hidden-when-unsupported test on a mocked probe.
- **R7.3** `xcodebuild` (Debug, macOS) green; no test count regression.
