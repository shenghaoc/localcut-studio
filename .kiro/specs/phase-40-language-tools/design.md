# Design: Phase 40 — On-Device Language Tools

> Status: **In progress on `next` branch**. Target tag: **v1.0.0** (parity with browser-editor v1). Targets macOS 27.

## Goal

(a) Translate Phase 30 caption tracks via Apple's on-device translation (`Translation` framework + `LanguageDetection`), producing a second caption track for bilingual export. (b) Draft titles, hashtags, and 文案 (copy) from the transcript via Apple's Foundation Models (the on-device LLM available from macOS 26+ on supported chips). Strictly progressive: on hosts where these frameworks return "model not available", the entire surface hides — no errors, no nags, no other feature depends on it.

The browser-editor restricts itself to Chrome's built-in `Translator` / `LanguageDetector` / `Summarizer` / `Prompt` APIs and hides everything on other browsers. The native port uses Apple's equivalent frameworks, with the same "hide on unavailable" discipline.

## Prerequisites

- Phase 30 caption tracks (the translation target).
- Phase 29 transcript (the draft source) when available; the panel works on manual captions too.
- `feature-project-persistence` so the second caption track persists.

## Approach

1. **Availability probe.** Before exposing any UI, the probe checks:
   - `LanguageAvailability.status(from: srcLang, to: dstLang)` (Translation framework) for the requested pair. The status enum distinguishes installed vs. supported (downloadable) vs. unsupported.
   - `SystemLanguageModel.default.availability` (Foundation Models, macOS 26+) for the draft pipeline. Switch on the result:
     ```swift
     switch SystemLanguageModel.default.availability {
     case .available:
         // expose UI
     case .unavailable(let reason):
         // hide UI; reason explains why (device not eligible, Apple Intelligence not enabled, model not ready)
     }
     ```
   - Hardware floor: Apple Silicon M-series + Apple Intelligence enabled + supported region. Translation has a wider compatibility footprint than Foundation Models — the two probes are independent and the panel hides only what's unavailable.
2. **Hide-on-unavailable.** Translation `.unsupported` hides the language; Foundation Models `.unavailable(.deviceNotEligible)` / `.unavailable(.appleIntelligenceNotEnabled)` hides the draft panel for good. Other `.unavailable(...)` reasons (e.g. `.modelNotReady` while a model downloads) keep the panel hidden but eligible for re-polling on app foreground. No error dialogs.
3. **Translation pipeline.**
   - Detect source language with `NLLanguageRecognizer` (Natural Language framework) on the first caption line — Apple's general-purpose language ID, distinct from the Translation framework's pair-availability probe.
   - `TranslationSession` is bound at the SwiftUI view boundary via `.translationTask(_:)` (`source:target:perform:`) — Apple gates the session on the modifier's view lifetime so the framework can show download / consent UI when needed. A pure `LanguageTranslator` actor batches caption lines into a request stream; the view-owned session iterates an `AsyncStream` of pending items via Swift 6 `async/await`, calls `session.translate(_:)` per item, and feeds results back through an `AsyncThrowingStream<TranslatedLine, Error>` the actor awaits. No legacy completion handlers — the call chain is async/await end to end.
   - For each translated text, the actor creates a mirrored `CaptionLine` with identical `CMTimeRange`.
   - Output lands as a SECOND `CaptionTrack` on the project. Bilingual SRT/VTT export pairs them per Phase 30's sidecar path (`stem.zh.srt`, `stem.en.srt`).
4. **Draft pipeline.**
   - `LanguageModelSession(model: SystemLanguageModel.default)` is the Foundation Models entry point; calls land on `respond(to:)` for plain prompts.
   - For structured output (titles list, hashtag set) use `@Generable` types so Foundation Models returns a typed `[String]` / struct instead of free-form text we'd have to parse — same WWDC25-shipped macro Apple recommends for typed responses.
   - Transcript → hierarchical summarisation under the Foundation Models token cap.
   - Three prompt templates: titles (3 candidates), hashtags (5–10), 文案 (Chinese long-form copy).
   - Outputs render in a read-only, copy-only panel. NEVER auto-applied to the project. The user copies what they want.
5. **Model download lifecycle.**
   - Translation pair states from `LanguageAvailability.status(from:to:)`: `.installed` enables the feature; `.supported` exposes a "translate" action that triggers the OS download UI on first call (delivered through `.translationTask` from the view boundary); `.unsupported` hides the pair.
   - Foundation Models states from `SystemLanguageModel.default.availability`: `.available` enables drafts; `.unavailable(.modelNotReady)` means the OS download is in progress — we poll on app foreground and unhide when the value flips to `.available`; `.unavailable(.deviceNotEligible)` / `.unavailable(.appleIntelligenceNotEnabled)` hide the panel for good (no download path).
   - We do NOT introduce browser-style `downloadable / downloading / ready` symbols. The UI switches on the Apple probe enums directly.
   - All models live in Apple's managed cache; we do NOT store them in the app sandbox.
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
