# Design: Phase 29 — On-Device Auto Captions

> Status: **Proposed**. Target tag: **v0.2.1**. Blocked on macOS 27 leaving beta.

## Goal

Apple-provided on-device ASR over selected clip audio, populating the Phase 30 caption-track model. Runs off-main-actor on a dedicated `actor`; ships as review-before-apply caption proposals; fully offline.

The browser-editor ships Whisper Base / Tiny ONNX via ORT-WASM because the web platform has no native ASR. The native port doesn't need to vendor a model: **Apple ships on-device ASR as a first-party framework (`Speech`)** — no model bundle, no manifest, no SHA-256 pinning, no download UX.

## Prerequisites

- Phase 30 caption track model (`CaptionTrack`, `CaptionLine`, `WordTiming`).
- `feature-project-persistence` for caption proposals to survive bundle round-trip.

## Approach

1. **Engine.** `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. Apple ships the ASR models with the OS; macOS 27 brings refreshed on-device models. Word-level segment timings come from `SFTranscriptionSegment.timestamp + duration` and feed `CaptionLine.words: [WordTiming]?` directly.
2. **Audio extraction.** `AVAssetReader` pulls clip audio. A `VadGate` (energy-based, hysteresis tuned for speech) skips silence and tightens segment boundaries before recognition.
3. **Worker.** A background `actor TranscriptionService` exposes `(asset, range, language?) -> AsyncThrowingStream<CaptionLine>` and runs windowed recognition with overlap stride. The actor isolates Speech-framework calls from the main actor.
4. **Language.** Auto-detect via `NLLanguageRecognizer` on a first-window transcript; user can force a language in the UI.
5. **Review-before-apply.** A modal surfaces proposed `CaptionLine`s with per-line apply / skip. Apply commits to the existing `CaptionTrack` in a single undoable transaction. Mirrors the Phase 44 silence-trim and Phase 33 reframe review patterns.

## Trade-offs

- Apple-provided model only — no BYO Whisper / Core AI custom model. The browser-editor needed Whisper because the web has no ASR API; we don't. We accept Apple's quality on Mandarin / code-switching as the v1 baseline and revisit only if creator feedback says otherwise.
- Word-level timing in Apple Speech is per-segment; Phase 30 karaoke highlight activates at segment granularity.

## Risks

- `SFSpeechRecognizer.requiresOnDeviceRecognition` returns `false` on older Macs that don't meet Apple's on-device floor. On those hosts the feature is hidden — no cloud fallback, no degraded path.
- DRM-protected audio sources fail at `AVAssetReader`; we surface this explicitly.

## Non-goals

- Translation (Phase 40).
- Speaker diarization.
- Filler-word removal (follow-up once richer timestamps are available).
- Streaming live captions.
- Bundled or downloadable Whisper / Core AI custom models.
