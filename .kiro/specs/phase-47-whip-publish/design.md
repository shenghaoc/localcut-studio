# Design: Phase 47 — WHIP Publish

> Status: **Proposed**. Target tag: **v0.1.14**.

## Goal

Stream the program feed — the same composited video and master-bus audio the preview plays — to a user-configured WHIP (RFC 9725) ingest endpoint. LocalCut acts as a standards-compliant WHIP client: POST SDP offer, receive answer, push media over WebRTC, DELETE on stop. The user brings the endpoint (Twitch WHIP, Cloudflare-class CDN, self-hosted MediaMTX); LocalCut never operates or proxies through relay infrastructure.

The browser-editor's v1 leans entirely on the platform's `RTCPeerConnection`. Native macOS has no built-in equivalent — `WKWebView` ships WebRTC but it cannot speak to the rest of the app. This phase therefore vendors a single non-trivial third-party dependency.

## Prerequisites

- Phase 41 (the encode pipeline whose output we tap).
- Phase 45 (the program output is the publish source).
- `EncoderBudget` actor (shared with Phase 45).

## Approach

1. **WebRTC stack.** Vendor **GoogleWebRTC** (`stable/M132` or later) via Swift Package Manager. Apache-2.0 licence, organisational backing (Google), industry-standard. Size on disk: ~80 MB as an XCFramework. We justify this AGENTS.md-significant addition because:
   - WHIP requires `RTCPeerConnection`; there is no Apple-native equivalent for SDP + ICE + DTLS-SRTP egress.
   - Apple's `WKWebView` WebRTC implementation cannot bridge to AVFoundation media pipelines.
   - All open-source alternatives (LiveKit-WebRTC, hand-rolled) wrap the same Google sources.
   - The dependency is gated behind a build flag; users who don't need streaming can drop it from a custom build.
2. **WHIP HTTP client.** `WhipClient` — pure Swift over `URLSession` (no WebRTC dep). Methods: `publish(offerSdp)`, `patchIceRestart(resourceUrl, fragment)`, `teardown(resourceUrl)`. Bearer token injected on every verb; tokens NEVER echoed in errors, logs, or diagnostics.
3. **Session orchestrator.** `WhipSession` actor owns the `RTCPeerConnection` (created via `RTCPeerConnectionFactory`), wires `sendonly` audio + video transceivers, applies codec preferences (H.264 baseline default, AV1 where the probe + endpoint allow), and drives the state machine:
   `idle → connecting → live → reconnecting → live / failed → ended`.
4. **Media taps.** Reuse Phase 45's `ProgramCompositor` output. The composited `CVPixelBuffer` feeds an `RTCVideoSource` via a custom `RTCVideoCapturer` subclass. Master-bus audio taps an `AVAudioEngine` node into an `RTCAudioSource` via `RTCAudioDeviceModule`'s I/O API. Both source classes are GoogleWebRTC public types.
5. **Reconnect policy.** 3 s grace on `disconnected`; on `failed` try ICE restart via PATCH (`application/trickle-ice-sdpfrag`); on 405 / 501 / restart failure, full re-POST as a new session. Backoff 2 s → 4 s → 8 s → 16 s → 16 s, max 5 attempts.
6. **Encoder budget.** Acquire `.whipPublish` from `EncoderBudget` before opening the peer connection. Record + stream simultaneous use is offered only when both leases are available; otherwise an explicit "drop one to stream" message.
7. **Codec defaults.** H.264 constrained baseline (`42e029`) is the lowest-common-denominator; AV1 gated on (probe says AV1 encode is available) AND (endpoint type known to accept it). Opus 128 kbps stereo for audio (WebRTC mandatory).
8. **Settings + secrets.** Endpoint URL and bearer token persist in a dedicated keychain entry (`com.localcut.studio.publish.<endpoint>`) NOT in `ProjectDoc`. Bundle export structurally cannot leak them. The bearer token is session-only unless the user opts into "remember on this device" with plain copy about how it's stored.

## Trade-offs

- GoogleWebRTC is an exception to "no third-party media libraries". We document this honestly: WHIP is otherwise impossible on macOS.
- WebRTC's media engine does the encoding (not VideoToolbox directly) — we lose some control vs. our normal pipeline, but get reconnect + congestion control + DTLS-SRTP for free.
- RTMP-only platforms (YouTube, Douyin, Bilibili) are NOT supported directly; users run a WHIP → RTMP gateway (MediaMTX is the documented recipe). LocalCut never operates relay infra.

## Risks

- GoogleWebRTC's API surface drifts between releases; we pin to a stable branch and update on a deliberate cadence.
- Build size bumps to ~150 MB total app (~70 MB current + GoogleWebRTC). Users see this clearly in release notes.
- Apple may ship a first-party `WebRTC` framework in a future macOS; we'd switch.

## Non-goals

- RTMP / SRT (no raw sockets via WHIP; SRT could be a separate spec via Apple's `NWConnection`).
- Simulcast / ABR ladders.
- Chat, overlays, alerts, platform APIs.
- Any hosted relay or account system.
