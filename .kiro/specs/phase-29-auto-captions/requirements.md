# Requirements: Phase 29 — On-Device Auto Captions

## R1 — ASR engine

- **R1.1** `SFSpeechRecognizer(locale:)` is the engine; every request additionally sets `SFSpeechRecognitionRequest.requiresOnDeviceRecognition = true`.
- **R1.2** Availability gate: `SFSpeechRecognizer(locale:)` is Optional — `nil` for unsupported locales. The probe is `guard let recognizer = SFSpeechRecognizer(locale:), recognizer.supportsOnDeviceRecognition else { return .unavailable }` and runs BEFORE the feature is exposed. Either branch hides the feature — no cloud fallback, no degraded path. The probe re-runs when the user changes language.
- **R1.3** Language is chosen at recognizer init from (a) explicit user override → (b) clip asset metadata → (c) system locale. The recognizer cannot change language after init; `NLLanguageRecognizer` runs only as an after-the-fact verification flag.

## R2 — Audio extraction + windowing

- **R2.1** `AVAssetReader` decodes clip audio in the format Speech expects.
- **R2.2** A VAD pre-pass (energy + hysteresis) skips silence and tightens segment boundaries.
- **R2.3** Windowed recognition uses overlap stride; window boundaries align to VAD output.

## R3 — Output model

- **R3.1** Output `[CaptionLine]` with `WordTiming` arrays at segment granularity — populates the Phase 30 `CaptionTrack`.
- **R3.2** Timeline timestamp mapping goes through the clip's source-to-timeline evaluator so Phase 35 speed ramps are honoured: `sourceTime = clip.sourceStart + windowOffsetInClip + segment.timestamp`, then `timelinePTS = clip.mapSourceTimeToTimeline(sourceTime)`. The same chain applies to every `WordTiming` and every `CaptionLine.range`. Tests assert proposals land within ±1 frame of the spoken audio on (a) an unramped trimmed-clip fixture, and (b) a ramped clip whose speed curve covers acceleration + deceleration.
- **R3.3** `NLLanguageRecognizer` runs after recognition only as a verification flag (proposal marked "likely wrong language" if it disagrees with the chosen locale); it is NOT the primary language source.

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
