# Tasks: Phase 29 — On-Device Auto Captions

> Status: **Proposed**. Depends on Phase 30 caption tracks + `feature-project-persistence`; blocked on macOS 27 leaving beta.

## Engine

- [ ] **T1.1** `actor TranscriptionService` — off-main-actor wrapper around Speech / Core ML.
- [ ] **T1.2** Tier A path: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`; segment → `CaptionLine`.
- [ ] **T1.3** Tier B path: Core ML Whisper Base loader + greedy decoder; word-token → `WordTiming` mapping.
- [ ] **T1.4** `ModelManifest.swift` — pinned SHA-256, on-disk path, version migration.
- [ ] **T1.5** `URLSession` background download with progress; cancellable.

## Audio pipeline

- [ ] **T2.1** `AVAssetReader` PCM 16 kHz mono extraction.
- [ ] **T2.2** Energy-based VAD with hysteresis tuned for speech.
- [ ] **T2.3** 30 s windowing with overlap stride.

## Language

- [ ] **T3.1** `NLLanguageRecognizer` first-window auto-detect.
- [ ] **T3.2** Forced-language picker in the UI.

## Review-before-apply

- [ ] **T4.1** Proposal model + transaction-based apply / skip.
- [ ] **T4.2** Modal UI with scrubbable preview.

## Verification

- [ ] **T5.1** Unit tests on a fixture transcript: word-timing within ±150 ms.
- [ ] **T5.2** Smoke: transcribe → review → apply → export.
- [ ] **T5.3** Determinism test in greedy mode.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
