# Tasks: Phase 40 — On-Device Language Tools

> Status: **Proposed**. Depends on Phase 30, Phase 29, persistence; blocked on macOS 27 leaving beta.

## Probes

- [ ] **T1.1** `LanguageAvailability.status(from:to:)` (Translation) + `SystemLanguageModel.default.availability` (FoundationModels) probes at app start; re-poll on foreground.
- [ ] **T1.2** Hide-on-unavailable wiring across the panel and menu items.

## Translation

- [ ] **T2.1** `LanguageTranslator` actor (pure batching + state machine; does NOT own a `TranslationSession`). `TranslationSession` is bound at the view boundary via the SwiftUI `.translationTask(_:)` modifier — Apple gates the session on the modifier's view lifetime so it can surface download / consent UI. Swift 6 concurrency throughout: the actor exposes `func translate(_ batch: [CaptionLine]) -> AsyncThrowingStream<TranslatedLine, Error>`; the view's `.translationTask` body iterates the source `AsyncStream` of pending lines from the actor, calls `session.translate(_:)` per item, and yields back into a continuation the actor awaits. No completion handlers, no callback bridging.
- [ ] **T2.2** `LanguageDetection` first-line source detection.
- [ ] **T2.3** Caption-line-by-caption-line translation preserving `CMTimeRange`.
- [ ] **T2.4** Second `CaptionTrack` model integration; paired sidecar export.

## Draft

- [ ] **T3.1** `actor DraftService` driving a `LanguageModelSession(model: SystemLanguageModel.default)`; uses `respond(to:)` for plain prompts and `@Generable` typed responses for structured outputs.
- [ ] **T3.2** Transcript hierarchical summariser fitting the Foundation Models token cap.
- [ ] **T3.3** Prompt templates: titles, hashtags, 文案 (typed via `@Generable` where structure matters).
- [ ] **T3.4** Read-only / copy-only draft panel.

## Download lifecycle

- [ ] **T4.1** `downloadable → downloading → ready` state machine surfaced in UI.
- [ ] **T4.2** Cancellable download.

## Verification

- [ ] **T5.1** Hidden-on-unavailable test.
- [ ] **T5.2** Translation timing preservation test.
- [ ] **T5.3** Smoke: translate → bilingual SRT export.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
