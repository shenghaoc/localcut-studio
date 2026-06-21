# Design: Phase 40 — On-Device Language Tools

> Status: **Proposed**. Target tag: **v1.0.0** (parity with browser-editor v1). Blocked on macOS 27 leaving beta.

## Goal

(a) Translate Phase 30 caption tracks via Apple's on-device translation (`Translation` framework + `LanguageDetection`), producing a second caption track for bilingual export. (b) Draft titles, hashtags, and 文案 (copy) from the transcript via Apple's Foundation Models (the on-device LLM available from macOS 26+ on supported chips). Strictly progressive: on hosts where these frameworks return "model not available", the entire surface hides — no errors, no nags, no other feature depends on it.

The browser-editor restricts itself to Chrome's built-in `Translator` / `LanguageDetector` / `Summarizer` / `Prompt` APIs and hides everything on other browsers. The native port uses Apple's equivalent frameworks, with the same "hide on unavailable" discipline.

## Prerequisites

- Phase 30 caption tracks (the translation target).
- Phase 29 transcript (the draft source) when available; the panel works on manual captions too.
- `feature-project-persistence` so the second caption track persists.

## Approach

1. **Availability probe.** Before exposing any UI, the probe checks:
   - `Translation.LanguageAvailability` for the requested pair (e.g. `zh-Hans → en`).
   - `LanguageModel.isAvailable` (`FoundationModels` framework) for the draft pipeline. Both APIs report `downloadable | downloading | ready | unavailable`.
   - Hardware floor: Apple Silicon M-series + ≥ 8 GB unified memory for Foundation Models (Apple's published floor); Translation works on all Apple Silicon.
2. **Hide-on-unavailable.** Anything other than `ready` (or `downloadable` post-user-consent) hides the entire panel. No error dialogs.
3. **Translation pipeline.**
   - Detect source language with `LanguageDetection` on the first caption line.
   - For each `CaptionLine`, run `TranslationSession.translate(text)` and create a mirrored `CaptionLine` with identical `CMTimeRange`.
   - Output lands as a SECOND `CaptionTrack` on the project. Bilingual SRT/VTT export pairs them per Phase 30's sidecar path (`stem.zh.srt`, `stem.en.srt`).
4. **Draft pipeline.**
   - Transcript → hierarchical summarisation under the Foundation Models token cap.
   - Three prompt templates: titles (3 candidates), hashtags (5–10), 文案 (Chinese long-form copy).
   - Outputs render in a read-only, copy-only panel. NEVER auto-applied to the project. The user copies what they want.
5. **Model download lifecycle.**
   - `downloadable` state offers a "Download translation model" button with size displayed (`Translation.LanguageAvailability.downloadSize` or equivalent).
   - `downloading` state shows progress; cancellable.
   - `ready` state enables the feature.
   - Models live in Apple's managed cache (we do NOT store them in the app sandbox).
6. **On-device guarantee.** No network calls beyond the OS-managed model download. Translation and drafting use the on-device APIs only. We assert this in design.md and document it in the user-facing docs.

## Trade-offs

- Apple's Translation framework is a tighter scope than Chrome's `Translator` — it ships well-supported language pairs and is the right default; we hide unsupported pairs rather than fall back to a worse model.
- Foundation Models is Apple Silicon only with a memory floor; Intel Macs see the draft panel hidden. Honest gating.
- Hierarchical summarisation for long transcripts mirrors the browser-editor approach; output quality is bounded by the on-device model size.

## Risks

- Apple may revise the Translation / Foundation Models APIs between betas; we feature-detect at runtime, never assume a specific symbol.
- A user might expect cloud-quality output; the UI states plainly that drafts are on-device.

## Non-goals

- Cloud LLM calls. There is no cloud fallback and none will ever be added.
- Auto-posting / platform integration.
- Full transcript rewriting.
- Dubbing / TTS.
- App-owned ONNX language models on hosts without Foundation Models (deferred — same decision the browser-editor made).
