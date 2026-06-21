# Tasks: Phase 40 — On-Device Language Tools

> Status: **Proposed**. Depends on Phase 30, Phase 29, persistence; blocked on macOS 27 leaving beta.

## Probes

- [ ] **T1.1** `Translation.LanguageAvailability` probe + `LanguageModel.isAvailable` probe at app start.
- [ ] **T1.2** Hide-on-unavailable wiring across the panel and menu items.

## Translation

- [ ] **T2.1** `LanguageTranslator` actor (pure batching + state machine; does NOT own a `TranslationSession`). `TranslationSession` is bound at the view boundary via the SwiftUI `.translationTask(_:)` modifier — Apple gates the session on the modifier's view lifetime so it can surface download / consent UI, and an actor-owned session would either miss those prompts or outlive its anchoring view. The actor receives `(line, completionHandler)` work items; the view-owned session passes the result back to the actor.
- [ ] **T2.2** `LanguageDetection` first-line source detection.
- [ ] **T2.3** Caption-line-by-caption-line translation preserving `CMTimeRange`.
- [ ] **T2.4** Second `CaptionTrack` model integration; paired sidecar export.

## Draft

- [ ] **T3.1** `actor DraftService` wrapping `FoundationModels.LanguageModel`.
- [ ] **T3.2** Transcript hierarchical summariser.
- [ ] **T3.3** Prompt templates: titles, hashtags, 文案.
- [ ] **T3.4** Read-only / copy-only draft panel.

## Download lifecycle

- [ ] **T4.1** `downloadable → downloading → ready` state machine surfaced in UI.
- [ ] **T4.2** Cancellable download.

## Verification

- [ ] **T5.1** Hidden-on-unavailable test.
- [ ] **T5.2** Translation timing preservation test.
- [ ] **T5.3** Smoke: translate → bilingual SRT export.
- [ ] **T5.4** `xcodebuild` (Debug, macOS) green.
