# Design: Phase 47 — WHIP Publish

> Status: **Proposed**. Target tag: **v0.1.14**.

## Goal

Stream the program feed — the same composited video and master-bus audio the preview plays — to a user-configured WHIP (RFC 9725) ingest endpoint. LocalCut acts as a standards-compliant WHIP client: POST SDP offer, receive answer, push media over WebRTC, DELETE on stop. The user brings the endpoint (Twitch WHIP, Cloudflare-class CDN, self-hosted MediaMTX); LocalCut never operates or proxies through relay infrastructure.

The browser-editor's v1 leans entirely on the platform's `RTCPeerConnection`. Native macOS has no built-in equivalent — `WKWebView` ships WebRTC but it cannot speak to the rest of the app. This phase therefore vendors a single non-trivial third-party dependency.

## Prerequisites

- Phase 41 (the encode pipeline whose output we tap).
- Phase 45 (the program output is the publish source).
- `EncoderBudget` actor (shared with Phase 45).
- Sandbox entitlement `com.apple.security.network.client` — required for outgoing HTTP + WebRTC traffic from a sandboxed app. Added at the time this phase starts and only then (we follow the steering rule "do not add entitlements speculatively").

## Current pre-merge status

Pre-merge validation on 2026-07-04 found that `stasel/WebRTC` releases 149.0.0 and 148.0.0 resolve through SwiftPM but do not compile for the macOS app target: the macOS framework slice exposes only `WebRTC.h`, while that umbrella header imports missing public headers such as `RTCAudioSource.h`. The fallback `webrtc-sdk/webrtc` repository does not currently provide a SwiftPM binary package that can be dropped into this Xcode project. Until the default macOS build links a WebRTC package successfully, all `#if canImport(WebRTC)` media/session code remains uncompiled in CI and the publish panel must stay in the reduced "WebRTC framework not available" state.

The WHIP HTTP client, settings storage, program-frame sink plumbing, and non-WebRTC safety tests are present, but the phase is not complete. The remaining blockers are:

- Pick and pin a macOS WebRTC package that compiles in the default app scheme, or rewrite this phase around a different supported WebRTC API surface.
- Replace the placeholder `LocalCutAudioDeviceModule.deliverCaptureFrame(_:)` with a real capture-side ADM bridge that feeds master-bus samples to WebRTC.
- Add the MediaMTX publish integration test required by the verification tasks.

## Approach

1. **WebRTC stack.** Apple's `WKWebView` WebRTC implementation can't bridge to AVFoundation, and the official **GoogleWebRTC CocoaPods** binary is iOS-only with no macOS slice — adding it via SPM would not link on the macOS target. We need a community-maintained macOS-capable WebRTC XCFramework via SPM, but the candidate must compile in the default app scheme before this task can be closed. `stasel/WebRTC` was the recommended primary for SPM simplicity, but the 149.0.0 and 148.0.0 macOS slices failed validation as noted above; `webrtc-sdk/webrtc` remains a research lead rather than a drop-in SwiftPM package. A replacement must repackage upstream `webrtc.googlesource.com` sources without forking the API, so the public surface (`RTCPeerConnection`, `RTCVideoSource`, `AudioDeviceModule`, etc.) matches Google's documentation. **BSD-3-Clause** licence (upstream LICENSE; additional patent grants ride alongside). Size on disk: expected ~80 MB as an XCFramework. We justify this AGENTS.md-significant addition because:
   - WHIP requires `RTCPeerConnection`; there is no Apple-native equivalent for SDP + ICE + DTLS-SRTP egress.
   - Apple's `WKWebView` WebRTC implementation cannot bridge to AVFoundation media pipelines.
   - All open-source alternatives (LiveKit-WebRTC, hand-rolled) wrap the same Google sources.
   - The dependency is gated behind a build flag; users who don't need streaming can drop it from a custom build.
2. **WHIP HTTP client.** `WhipClient` — pure Swift over `URLSession` (no WebRTC dep). Methods: `publish(offerSdp)` returning `(resourceUrl, etag, iceServers, answerSdp)`, `patchIceRestart(resourceUrl, fragment, etag)`, `teardown(resourceUrl)`. The publish response's `ETag` is captured and forwarded as an `If-Match` header on every PATCH per RFC 9725 §4.3.1 — strict servers return 412 Precondition Failed (or 428 Precondition Required) when this is missing or stale. The PATCH response carries a fresh `ETag` which replaces the cached one for the next restart. Bearer tokens are injected on every verb but NEVER echoed in errors, logs, or diagnostics.
3. **Session orchestrator.** `WhipSession` actor owns the `RTCPeerConnection` (created via `RTCPeerConnectionFactory`), wires `sendonly` audio + video transceivers, applies codec preferences (H.264 baseline default, AV1 where the probe + endpoint allow), and drives the state machine:
   `idle → connecting → live → reconnecting → live / failed → ended`.
4. **Media taps.** Reuse Phase 45's `ProgramCompositor` output. The composited `CVPixelBuffer` feeds an `RTCVideoSource` via a custom `RTCVideoCapturer` subclass. **Audio is harder than the symmetric "use `RTCAudioSource`" claim might suggest:** GoogleWebRTC's Swift/Obj-C SDK does NOT expose a public push-PCM API on `RTCAudioSource` / `RTCAudioTrack`. Audio enters the WebRTC engine through an `AudioDeviceModule` (ADM) — a C++ interface that exposes both a playout side (the engine PULLS samples via `NeedMorePlayData`) and a capture / recording side (the ADM PUSHES samples via `AudioTransport::RecordedDataIsAvailable`). For our `sendonly` WHIP session we feed the capture side: master-bus samples are pulled from an `AVAudioSinkNode` into a ring buffer; a dedicated capture thread delivers fixed-size 10 ms frames into `RecordedDataIsAvailable`. We ship one minimal ADM (~200 lines of C++) wrapped behind a Swift facade. This is the unavoidable interop cost of using GoogleWebRTC; any RTCAudioDeviceModule-named symbol referenced in earlier drafts is not part of the vanilla GoogleWebRTC public surface, and routing master-bus audio into `NeedMorePlayData` would feed the local playout, not the outbound stream.
5. **Reconnect policy.** 3 s grace on `disconnected`; on `failed` try ICE restart via PATCH (`application/trickle-ice-sdpfrag`) with the cached `If-Match` ETag; on 405 / 501 / 412 / 428 / restart failure, full re-POST as a new session (which yields a fresh ETag). Backoff 2 s → 4 s → 8 s → 16 s → 16 s, max 5 attempts.
6. **Encoder budget.** Acquire `.whipPublish` from `EncoderBudget` before opening the peer connection. Record + stream simultaneous use is offered only when both leases are available; otherwise an explicit "drop one to stream" message.
7. **Codec defaults.** H.264 constrained baseline (`42e029`) is the lowest-common-denominator; AV1 gated on (probe says AV1 encode is available) AND (endpoint type known to accept it). Opus 128 kbps stereo for audio (WebRTC mandatory).
8. **Settings + secrets.** Endpoint URL persists in app-scoped settings (NOT `ProjectDoc`). The bearer token defaults to in-memory **session-only** — typed once, never written to disk, dropped at app quit. Only after the user explicitly opts into "Remember on this device" does it move into a Keychain entry (`com.localcut.studio.publish.<endpoint>`); the opt-in dialog states plainly that the token then lives unencrypted in the Keychain like an OBS stream key. Bundle export structurally cannot leak the token because it's never in `ProjectDoc`.

## Trade-offs

- The community WebRTC XCFramework (`stasel/WebRTC` / `webrtc-sdk/webrtc`) is an exception to "no third-party media libraries". We document this honestly: WHIP is otherwise impossible on macOS, and these packages repackage the same upstream sources Google maintains.
- WebRTC's media engine does the encoding (not VideoToolbox directly) — we lose some control vs. our normal pipeline, but get reconnect + congestion control + DTLS-SRTP for free.
- RTMP-only platforms (YouTube, Douyin, Bilibili) are NOT supported directly; users run a WHIP → RTMP gateway (MediaMTX is the documented recipe). LocalCut never operates relay infra.

## Risks

- The community WebRTC XCFramework's API surface drifts with upstream WebRTC; we pin to a milestone-tagged release and update on a deliberate cadence.
- Build size bumps to ~150 MB total app (~70 MB current + ~80 MB community WebRTC XCFramework). Users see this clearly in release notes.
- Apple may ship a first-party `WebRTC` framework in a future macOS; we'd switch.

## Non-goals

- RTMP / SRT (no raw sockets via WHIP; SRT could be a separate spec via Apple's `NWConnection`).
- Simulcast / ABR ladders.
- Chat, overlays, alerts, platform APIs.
- Any hosted relay or account system.
