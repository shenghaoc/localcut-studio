# Tasks: Phase 47 — WHIP Publish

> Status: **Implemented**. Depends on Phase 41 + Phase 45 + `EncoderBudget`.
>
> Pre-merge validation on 2026-07-05 uses `stasel/WebRTC` 140.0.0 (M140),
> linked through `Packages/LocalCutWebRTC`, with the macOS header wrapper
> sanitized for AppKit builds. The default build enables WebRTC with
> `LOCALCUT_ENABLE_WEBRTC`; custom builds can remove that flag and the package
> product for a reduced publish UI. Local `xcodebuild test` passes with the
> MediaMTX suite disabled by default; the CI script starts MediaMTX with
> Docker/Podman when available or a pinned verified macOS release binary on
> GitHub-hosted runners, then enables the required suite. Follow-up CI also
> prepares the pinned WebRTC XCFramework once per run, shares it between Xcode
> jobs as an artifact, and runs a flag-stripped non-WebRTC `xcodebuild test`
> pass to compile and exercise the fallback stubs. All Xcode CI test
> invocations use a 300-second per-test timeout so one hung test cannot consume
> the 30-minute job budget.

## Dependency + entitlements

- [x] **T1.1** Add a macOS-capable WebRTC XCFramework via SPM (selected: `stasel/WebRTC` 140.0.0 through `Packages/LocalCutWebRTC`; 141.0.0+ release artifacts tested so far have broken macOS public headers), pinned to a stable release. The official GoogleWebRTC CocoaPods binary is iOS-only and would not link the macOS target. Document size + licence (BSD-3-Clause) in design.md and `docs/USER-GUIDE.md`; record which package + release we picked.
- [x] **T1.2** Build flag to drop the WebRTC runtime path for users who don't need streaming, plus CI coverage that strips `LOCALCUT_ENABLE_WEBRTC` and exercises the fallback stubs.
- [x] **T1.3** Add `com.apple.security.network.client` to the entitlements file (sandbox blocks outgoing HTTP + WebRTC without it). Smoke-test that the publish flow makes its first POST under the sandbox.

## WHIP client

- [x] **T2.1** `WhipClient` — pure Swift over `URLSession`; POST / PATCH / DELETE; injectable `URLSession` for tests.
- [x] **T2.2** Bearer-token redaction in errors + logs.
- [x] **T2.3** Link-header `ice-server` parser including TURN credentials.

## Session orchestrator

- [x] **T3.1** `WhipSession` actor with `RTCPeerConnection` + state machine.
- [x] **T3.2** Codec preferences + bitrate wiring; keyframe interval is labelled best-effort because the pinned WebRTC macOS sender API does not expose deterministic GOP control.
- [x] **T3.3** Reconnect controller with backoff ladder + PATCH fallback.

## Media taps

- [x] **T4.1** `RTCVideoCapturer` subclass fed by Phase 45 program output.
- [x] **T4.2** Custom `RTCAudioDevice` bridge wrapped behind `AudioPublishBridge`. WHIP is `sendonly`, so outbound audio rides the WebRTC **capture / recording** transport (`RTCAudioDeviceDelegate.deliverRecordedData`), NOT the playout path. Master-bus samples are pushed into a ring buffer; a dedicated capture thread delivers fixed-size Int16 PCM frames at the 10 ms cadence WebRTC expects. The playout side stays inert in this sendonly session.

## Settings

- [x] **T5.1** Endpoint store in app settings (NOT `ProjectDoc`).
- [x] **T5.2** Keychain integration for tokens.
- [x] **T5.3** Bundle exclusion assertion.

## UI

- [x] **T6.1** `PublishPanel` view: endpoint type, URL, token, endpoint-gated codec picker, bitrate, best-effort keyframe interval, RTMP-honesty copy.
- [x] **T6.2** Live state + stats display + reduced-tier explanation.

## Verification

- [x] **T7.1** Unit tests for client + reconnect + budget.
- [x] **T7.2** CI integration test publishing to MediaMTX under the CI harness.
- [x] **T7.3** Bundle-exclusion test.
- [x] **T7.4** `xcodebuild` (Debug, macOS) green for both the default WebRTC-enabled app path and the non-WebRTC stub path, with Xcode per-test timeouts enabled on both CI lanes and the focused MediaMTX integration run.
