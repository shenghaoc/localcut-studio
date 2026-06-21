# Tasks: Phase 29 — On-Device Auto Captions

> Status: **Proposed**. Depends on Phase 30 caption tracks + `feature-project-persistence`; blocked on macOS 27 leaving beta.

## Engine

- [ ] **T1.1** `actor TranscriptionService` — off-main-actor wrapper around `SFSpeechRecognizer`.
- [ ] **T1.2** Three-step availability gate: optional `SFSpeechRecognizer(locale:)` → `supportsOnDeviceRecognition` → `await SFSpeechRecognizer.requestAuthorization(...)`. `Info.plist` ships `NSSpeechRecognitionUsageDescription`. Hide feature on any branch failing.
- [ ] **T1.3** Map `SFTranscriptionSegment` → `CaptionLine` + `WordTiming` array (segment granularity); timeline offset goes through `clip.mapSourceTimeToTimeline(...)`.

## Audio pipeline

- [ ] **T2.1** `AVAssetReader` PCM extraction in Speech's expected format.
- [ ] **T2.2** Energy-based VAD with hysteresis tuned for speech.
- [ ] **T2.3** Windowed recognition capped at 50 s windows with 2 s overlap stride; stitcher dedupes word sequences in the overlap.

## Language

- [ ] **T3.1** Locale picker BEFORE recognizer init: explicit user override → clip asset metadata → system locale fallback. Each `SFSpeechRecognizer` instance is created with the chosen locale and cannot change it after.
- [ ] **T3.2** Post-recognition verification via `NLLanguageRecognizer` on the resulting transcript; flag the proposal "likely wrong language — re-run as XX?" when detection disagrees with the chosen locale.
- [ ] **T3.3** Forced-language picker in the UI overrides everything.

## Review-before-apply

- [ ] **T4.1** Proposal model + transaction-based apply / skip.
- [ ] **T4.2** Modal UI with scrubbable preview.

## Verification

- [ ] **T5.1** Smoke: transcribe → review → apply → export.
- [ ] **T5.2** Hidden-when-unsupported test on a mocked probe.
- [ ] **T5.3** `xcodebuild` (Debug, macOS) green.
