# Tasks: Phase 47 — WHIP Publish

> Status: **Proposed**. Depends on Phase 41 + Phase 45 + `EncoderBudget`.

## Dependency

- [ ] **T1.1** Add GoogleWebRTC via SPM, pinned to a stable release; document size + licence in design.md and `docs/USER-GUIDE.md`.
- [ ] **T1.2** Build flag to drop the dep for users who don't need streaming.

## WHIP client

- [ ] **T2.1** `WhipClient` — pure Swift over `URLSession`; POST / PATCH / DELETE; injectable `URLSession` for tests.
- [ ] **T2.2** Bearer-token redaction in errors + logs.
- [ ] **T2.3** Link-header `ice-server` parser including TURN credentials.

## Session orchestrator

- [ ] **T3.1** `WhipSession` actor with `RTCPeerConnection` + state machine.
- [ ] **T3.2** Codec preferences + bitrate / keyframe parameter wiring.
- [ ] **T3.3** Reconnect controller with backoff ladder + PATCH fallback.

## Media taps

- [ ] **T4.1** `RTCVideoCapturer` subclass fed by Phase 45 program output.
- [ ] **T4.2** Audio tap from `AVAudioEngine` master bus to `RTCAudioSource`.

## Settings

- [ ] **T5.1** Endpoint store in app settings (NOT `ProjectDoc`).
- [ ] **T5.2** Keychain integration for tokens.
- [ ] **T5.3** Bundle exclusion assertion.

## UI

- [ ] **T6.1** `PublishPanel` view: endpoint type, URL, token, codec / bitrate / keyframe, RTMP-honesty copy.
- [ ] **T6.2** Live state + stats display + reduced-tier explanation.

## Verification

- [ ] **T7.1** Unit tests for client + reconnect + budget.
- [ ] **T7.2** CI integration test publishing to MediaMTX in a container.
- [ ] **T7.3** Bundle-exclusion test.
- [ ] **T7.4** `xcodebuild` (Debug, macOS) green.
