# Design: Phase 29 — On-Device Auto Captions

> Status: **Proposed**. Target tag: **v0.2.1**. Blocked on macOS 27 leaving beta.

## Goal

Whisper-class ASR over selected clip audio, populating the Phase 30 caption-track model with **word-level** timings so its karaoke highlight activates. Runs off-main-actor on a dedicated `actor`; ships as review-before-apply caption proposals; fully offline after first model fetch.

The browser-editor ships **Whisper Base / Tiny ONNX (int8)** via ORT-WASM in a dedicated ASR worker, manifest-pinned by SHA-256, fed from PCM windows produced by the pipeline worker. The native port replaces ORT-WASM with Apple's stack.

## Prerequisites

- Phase 30 caption track model (`CaptionTrack`, `CaptionLine`, `WordTiming`).
- `feature-project-persistence` for caption proposals to survive bundle round-trip.

## Approach

1. **Engine tiering.**
   - **Tier A (default on macOS 27+):** Apple's on-device Speech framework with `requiresOnDeviceRecognition = true`. Newer macOS exposes higher-quality on-device models through `SFSpeechRecognizer`'s refreshed back-end. Word-level segment timings come from `SFTranscriptionSegment.timestamp + duration`.
   - **Tier B (optional higher-accuracy download):** a Whisper Core ML model — Apple ships official Core ML conversions of Whisper Base / Small. Size: Base ≈ 145 MB on disk post-compile, Tiny ≈ 75 MB. We bundle a small (Base) by default; Tiny is an explicit "download lighter model" option.
   - The chosen model + its on-disk path + SHA-256 are recorded in a `ModelManifest.swift` alongside Apple-recommended cache locations; downloads use `URLSession` with progress surfaced before any fetch.
2. **Audio extraction.** `AVAssetReader` pulls clip audio at 16 kHz mono Float32 (Whisper input). A `VadGate` (energy-based, hysteresis tuned for speech) skips silence and tightens segment boundaries before windowed inference.
3. **Worker.** A background `actor TranscriptionService` accepts `(asset, range, language?) -> AsyncThrowingStream<CaptionLine>` and runs windowed inference (~30 s with overlap stride). Output is `CaptionLine` with a `words: [WordTiming]` array. The actor isolates Core ML / Speech calls from the main actor.
4. **Language.** Auto-detect via `NLLanguageRecognizer` on a first-window transcript (or `AVSpeechSynthesisVoice.currentLanguageCode` as a hint); user can force a language in the UI.
5. **Review-before-apply.** A modal surfaces proposed `CaptionLine`s and per-line apply / skip. Apply commits the lines into the existing `CaptionTrack` in a single undoable transaction. Mirrors the Phase 44 silence-trim and Phase 33 reframe review patterns.
6. **Determinism in tests.** Greedy decoding mode (no temperature ladder) for fixture stability.

## Trade-offs

- Apple's Speech framework integrates with no model-download UX (already on-device on macOS 26+) and is the obvious default; Whisper Core ML is the path for users who want better Mandarin / code-switching quality at the cost of a one-time download.
- Word-level timing in Apple Speech is per-segment, not per-glyph; Whisper Core ML provides token-level timings we map to words. The UI must note when word highlights are coarser (Tier A only).
- We do NOT ship a "phrase-level" web-style fallback — that's the browser's only-option; on macOS the on-device Speech framework already covers that case.

## Risks

- `SFSpeechRecognizer.requiresOnDeviceRecognition` returns `false` on older / smaller Macs. The capability probe surfaces this; on those hosts the only path is Tier B (Whisper Core ML).
- DRM-protected audio sources fail at `AVAssetReader`; we surface this explicitly.
- The Whisper Core ML download lives in the app's sandbox container; bundle export does NOT carry it (it is regenerable by re-download).

## Non-goals

- Translation (Phase 40).
- Speaker diarization.
- Filler-word removal (follow-up once word timestamps exist).
- Streaming live captions.
