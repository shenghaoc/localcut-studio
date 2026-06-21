# Design: Phase 29 — On-Device Auto Captions

> Status: **Proposed**. Target tag: **v0.2.1**. Blocked on macOS 27 leaving beta.

## Goal

Apple-provided on-device ASR over selected clip audio, populating the Phase 30 caption-track model. Runs off-main-actor on a dedicated `actor`; ships as review-before-apply caption proposals; fully offline.

The browser-editor ships Whisper Base / Tiny ONNX via ORT-WASM because the web platform has no native ASR. The native port doesn't need to vendor a model: **Apple ships on-device ASR as a first-party framework (`Speech`)** — no model bundle, no manifest, no SHA-256 pinning, no download UX.

## Prerequisites

- Phase 30 caption track model (`CaptionTrack`, `CaptionLine`, `WordTiming`).
- `feature-project-persistence` for caption proposals to survive bundle round-trip.

## Approach

1. **Availability probe.** Construct a `SFSpeechRecognizer(locale:)` for the chosen locale and read its instance property `supportsOnDeviceRecognition` BEFORE exposing the feature. If `false`, the feature is hidden — no cloud fallback, no degraded path. The request-side flag `SFSpeechRecognitionRequest.requiresOnDeviceRecognition = true` is set on every request as belt-and-braces, but the gate is the recognizer's instance probe.
2. **Engine + locale.** `SFSpeechRecognizer(locale:)` takes the language at init and cannot change it after; the language must be chosen BEFORE recognition starts. Three sources, in order: (a) explicit user override in the inspector; (b) language read from the clip's source asset metadata where available; (c) the system locale as a documented default. Auto-detect from the transcript happens too late to be the primary path — `NLLanguageRecognizer` only runs as a verification step AFTER recognition, flagging the proposal as "likely wrong language — re-run as XX?" when it disagrees with the chosen locale. Word-level segment timings come from `SFTranscriptionSegment.timestamp + duration`.
3. **Audio extraction + windowing.** `AVAssetReader` pulls clip audio. A `VadGate` (energy-based, hysteresis tuned for speech) skips silence and tightens segment boundaries before recognition. Each recognition window covers a known `(clipTimelineStart, windowOffsetInClip, windowDuration)` triple so step 4 can place the result correctly.
4. **Worker.** A background `actor TranscriptionService` exposes `(asset, clip, locale) -> AsyncThrowingStream<CaptionLine>` and runs windowed recognition with overlap stride. The actor isolates Speech-framework calls from the main actor.
5. **Timeline offset.** `SFTranscriptionSegment.timestamp` is relative to the audio buffer fed to the recognizer (window-start, NOT clip-start, NOT timeline-start). The mapping must add both offsets:
   ```
   timelinePTS = clip.timelineStart + windowOffsetInClip + segment.timestamp
   ```
   Same for `WordTiming` and `CaptionLine.range`. Apply this before the result reaches `CaptionTrack`; review modal previews validate the offset against the playhead.
6. **Review-before-apply.** A modal surfaces proposed `CaptionLine`s with per-line apply / skip. Apply commits to the existing `CaptionTrack` in a single undoable transaction. Mirrors the Phase 44 silence-trim and Phase 33 reframe review patterns.

## Trade-offs

- Apple-provided model only — no BYO Whisper / Core AI custom model. The browser-editor needed Whisper because the web has no ASR API; we don't. We accept Apple's quality on Mandarin / code-switching as the v1 baseline and revisit only if creator feedback says otherwise.
- Word-level timing in Apple Speech is per-segment; Phase 30 karaoke highlight activates at segment granularity.

## Risks

- `SFSpeechRecognizer.supportsOnDeviceRecognition` is `false` on older Macs and on locales that lack on-device support. On those hosts the feature is hidden — no cloud fallback, no degraded path.
- DRM-protected audio sources fail at `AVAssetReader`; we surface this explicitly.

## Non-goals

- Translation (Phase 40).
- Speaker diarization.
- Filler-word removal (follow-up once richer timestamps are available).
- Streaming live captions.
- Bundled or downloadable Whisper / Core AI custom models.
