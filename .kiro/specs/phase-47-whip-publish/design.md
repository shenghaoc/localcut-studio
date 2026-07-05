# Design: Phase 47 — WHIP Publish

> Status: **Implemented**. Target tag: **v0.1.14**.

## Goal

Stream the program feed — the same composited video and master-bus audio the preview plays — to a user-configured WHIP (RFC 9725) ingest endpoint. LocalCut acts as a standards-compliant WHIP client: POST SDP offer, receive answer, push media over WebRTC, DELETE on stop. The user brings the endpoint (Twitch WHIP, Cloudflare-class CDN, self-hosted MediaMTX); LocalCut never operates or proxies through relay infrastructure.

The browser-editor's v1 leans entirely on the platform's `RTCPeerConnection`. Native macOS has no built-in equivalent — `WKWebView` ships WebRTC but it cannot speak to the rest of the app. This phase therefore vendors a single non-trivial third-party dependency.

## Prerequisites

- Phase 41 (the encode pipeline whose output we tap).
- Phase 45 (the program output is the publish source).
- `EncoderBudget` actor (shared with Phase 45).
- Sandbox entitlement `com.apple.security.network.client` — required for outgoing HTTP + WebRTC traffic from a sandboxed app. Added at the time this phase starts and only then (we follow the steering rule "do not add entitlements speculatively").

## Current pre-merge status

Pre-merge validation on 2026-07-04 found that `stasel/WebRTC` releases 149.0.0 and 148.0.0 resolve through SwiftPM but do not compile for the macOS app target: the macOS framework slice exposes only `WebRTC.h`, while that umbrella header imports missing public headers such as `RTCAudioSource.h`. Follow-up validation on 2026-07-05 checked older stasel releases and selected **`stasel/WebRTC` 140.0.0 (M140)** as the newest verified stasel release before that macOS header-packaging regression. M140's macOS slice contains the required peer-connection, video-source, and `RTCAudioDevice` APIs after the local wrapper sanitizes the macOS umbrella/header set to exclude UIKit and `AVAudioSession` imports.

The WHIP HTTP client, settings storage, program-frame sink plumbing, WebRTC package linkage, capture-side audio bridge, and MediaMTX integration harness are implemented. The default app/test build enables the dependency with `LOCALCUT_ENABLE_WEBRTC`; custom builds can remove that flag and the package product to compile the reduced publish UI. Local `xcodebuild test` passed with the MediaMTX suite disabled by default because this machine has no Docker/Podman runtime. CI runs `Scripts/run-mediamtx-whip-integration.sh`, which starts MediaMTX through Docker/Podman when available or a pinned verified macOS release binary on GitHub-hosted runners, then enables the test suite with `LOCALCUT_RUN_MEDIAMTX_INTEGRATION=1`.

## Approach

1. **WebRTC stack.** Apple's `WKWebView` WebRTC implementation can't bridge to AVFoundation, and the official **GoogleWebRTC CocoaPods** binary is iOS-only with no macOS slice — adding it via SPM would not link on the macOS target. We vendor `stasel/WebRTC` **140.0.0 (M140)** through the local `Packages/LocalCutWebRTC` SwiftPM binary wrapper. M140 is older than the latest stasel milestone, but it is the newest stasel release validated with the required macOS APIs in this repo. Releases 141.0.0, 146.0.0, 148.0.0, and 149.0.0 expose only `WebRTC.h` in the macOS slice while the umbrella header imports missing `RTC*.h` headers. The wrapper download script pins the checksum, fills the missing public headers from the iOS slice when needed, removes iOS-only UIKit/`AVAudioSession` headers from the macOS umbrella, and validates existing downloads before returning. **BSD-3-Clause** licence (upstream LICENSE; additional patent grants ride alongside). Size on disk: ~87 MB as an extracted XCFramework. We justify this AGENTS.md-significant addition because:
   - WHIP requires `RTCPeerConnection`; there is no Apple-native equivalent for SDP + ICE + DTLS-SRTP egress.
   - Apple's `WKWebView` WebRTC implementation cannot bridge to AVFoundation media pipelines.
   - All open-source alternatives (LiveKit-WebRTC, hand-rolled) wrap the same Google sources.
   - The dependency is gated behind `LOCALCUT_ENABLE_WEBRTC`; users who don't need streaming can drop it from a custom build.
2. **WHIP HTTP client.** `WhipClient` — pure Swift over `URLSession` (no WebRTC dep). Methods: `publish(offerSdp)` returning `(resourceUrl, etag, iceServers, answerSdp)`, `patchIceRestart(resourceUrl, fragment, etag)`, `teardown(resourceUrl)`. The publish response's `ETag` is captured and every PATCH sends `If-Match: *` for RFC 9725 ICE restarts; strict servers return 412 Precondition Failed (or 428 Precondition Required) when restart preconditions are not met. PATCH bodies are ICE SDP fragments (`application/trickle-ice-sdpfrag`), not full session descriptions. The PATCH response's fresh `ETag` replaces the cached one for the next restart. Bearer tokens are injected on every verb but NEVER echoed in errors, logs, or diagnostics.
3. **Session orchestrator.** `WhipSession` actor owns the `RTCPeerConnection` (created via `RTCPeerConnectionFactory`), wires `sendonly` audio + video transceivers, applies WHIP-returned ICE servers to the live peer connection before setting the answer, applies codec preferences (H.264 baseline default, AV1 where the probe + endpoint allow), and drives the state machine:
   `idle → connecting → live → reconnecting → live / failed → ended`.
4. **Media taps.** Reuse Phase 45's `ProgramCompositor` output. The composited `CVPixelBuffer` feeds an `RTCVideoSource` via a custom `RTCVideoCapturer` subclass bound to the same `RTCPeerConnectionFactory` that owns the peer connection. **Audio is harder than the symmetric "use `RTCAudioSource`" claim might suggest:** GoogleWebRTC's Swift/Obj-C SDK does NOT expose a public push-PCM API on `RTCAudioSource` / `RTCAudioTrack`. In M140, outbound audio can be supplied by injecting a custom `RTCAudioDevice` into `RTCPeerConnectionFactory(encoderFactory:decoderFactory:audioDevice:)`. For our `sendonly` WHIP session we feed the capture / recording side: master-bus samples are pushed into `AudioPublishBridge`, buffered in a ring, converted from Float32 to Int16 PCM, wrapped in `AudioBufferList`, and delivered at a fixed 10 ms cadence through `RTCAudioDeviceDelegate.deliverRecordedData`. The playout side stays inert so we do not route publish audio into local playback.
5. **Reconnect policy.** 3 s grace on `disconnected`; a recovery to `connected` during grace cancels the pending reconnect. On `failed`, try ICE restart via PATCH (`application/trickle-ice-sdpfrag`) with the cached validator before full re-POST. On 405 / 501 / 412 / 428 / restart failure, DELETE the old resource and full re-POST as a new session (which yields a fresh ETag). Backoff 2 s → 4 s → 8 s → 16 s → 16 s, max 5 attempts. Terminal failure sends DELETE before clearing the resource URL.
6. **Encoder budget.** Acquire `.whipPublish` from `EncoderBudget` before opening the peer connection. Record + stream simultaneous use is offered only when both leases are available; otherwise an explicit "drop one to stream" message.
7. **Codec defaults.** H.264 constrained baseline (`42e029`) is the lowest-common-denominator; AV1 is hidden unless the local encode probe and endpoint type both allow it. Opus 128 kbps stereo for audio (WebRTC mandatory). WebRTC's M140 macOS sender API exposes bitrate limits but not deterministic GOP/keyframe interval control, so the keyframe interval UI is labelled best-effort.
8. **Settings + secrets.** Endpoint URL persists in app-scoped settings (NOT `ProjectDoc`). The bearer token defaults to in-memory **session-only** — typed once, never written to disk, dropped at app quit. Only after the user explicitly opts into "Remember on this device" does it move into a Keychain entry (`com.localcut.studio.publish.<endpoint>`); the opt-in dialog states plainly that the token then lives unencrypted in the Keychain like an OBS stream key. Bundle export structurally cannot leak the token because it's never in `ProjectDoc`.

## Trade-offs

- The community WebRTC XCFramework (`stasel/WebRTC`) is an exception to "no third-party media libraries". We document this honestly: WHIP is otherwise impossible on macOS, and stasel repackages the same upstream sources Google maintains.
- WebRTC's media engine does the encoding (not VideoToolbox directly) — we lose some control vs. our normal pipeline, but get reconnect + congestion control + DTLS-SRTP for free.
- RTMP-only platforms (YouTube, Douyin, Bilibili) are NOT supported directly; users run a WHIP → RTMP gateway (MediaMTX is the documented recipe). LocalCut never operates relay infra.

## Risks

- The community WebRTC XCFramework's API surface drifts with upstream WebRTC. M140 is deliberately pinned because newer stasel artifacts have a macOS packaging regression; upgrading needs a repeat header/import/build validation pass.
- Build size bumps to roughly ~157 MB total app (~70 MB current + ~87 MB community WebRTC XCFramework). Users see this clearly in release notes.
- Apple may ship a first-party `WebRTC` framework in a future macOS; we'd switch.

## Non-goals

- RTMP / SRT (no raw sockets via WHIP; SRT could be a separate spec via Apple's `NWConnection`).
- Simulcast / ABR ladders.
- Chat, overlays, alerts, platform APIs.
- Any hosted relay or account system.
