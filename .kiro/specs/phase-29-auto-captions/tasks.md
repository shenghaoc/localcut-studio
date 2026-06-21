# Tasks: Phase 29 — On-Device Auto Captions

> Status: **Proposed**. Depends on Phase 30 caption tracks + `feature-project-persistence`; blocked on macOS 27 leaving beta.

## Engine

- [ ] **T1.1** `actor TranscriptionService` — off-main-actor wrapper around `SFSpeechRecognizer`.
- [ ] **T1.2** Configure recognition with `requiresOnDeviceRecognition = true`; hide feature when unsupported.
- [ ] **T1.3** Map `SFTranscriptionSegment` → `CaptionLine` + `WordTiming` array (segment granularity).

## Audio pipeline

- [ ] **T2.1** `AVAssetReader` PCM extraction in Speech's expected format.
- [ ] **T2.2** Energy-based VAD with hysteresis tuned for speech.
- [ ] **T2.3** Windowed recognition with overlap stride aligned to VAD boundaries.

## Language

- [ ] **T3.1** `NLLanguageRecognizer` first-window auto-detect.
- [ ] **T3.2** Forced-language picker in the UI.

## Review-before-apply

- [ ] **T4.1** Proposal model + transaction-based apply / skip.
- [ ] **T4.2** Modal UI with scrubbable preview.

## Verification

- [ ] **T5.1** Smoke: transcribe → review → apply → export.
- [ ] **T5.2** Hidden-when-unsupported test on a mocked probe.
- [ ] **T5.3** `xcodebuild` (Debug, macOS) green.
