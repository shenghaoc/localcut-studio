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

Pre-merge validation found that newer `stasel/WebRTC` releases have a macOS public-header packaging regression (also tracked upstream in issue #145 for M147). M128 and M140 build the ordinary macOS module, but they omit the public `RTCAudioDevice` declaration needed by LocalCut's former custom-audio bridge. The dependency was therefore replaced with **`webrtc-sdk/Specs` 125.6422.09 (M125)**: an actively maintained, checksum-pinned distribution with the supported public AVAudioEngine device-module input hook. LiveKit builds its symbol-prefixed WebRTC XCFramework from the same `webrtc-sdk` source/build repositories, providing an independent production consumer of this distribution.

The WHIP HTTP client, settings storage, program-frame sink plumbing, WebRTC package linkage, capture-side audio bridge, and MediaMTX integration harness are implemented in the macOS-only `LocalCutPlatform` target. WebRTC is a required platform dependency; Linux excludes the entire target rather than substituting another implementation. Local `xcodebuild test` passed with the MediaMTX suite disabled by default because this machine has no Docker/Podman runtime. CI runs `Scripts/run-mediamtx-whip-integration.sh`, which starts MediaMTX through Docker/Podman when available or a pinned verified macOS release binary on GitHub-hosted runners, retries startup/readiness failures, then enables the test suite with `LOCALCUT_RUN_MEDIAMTX_INTEGRATION=1`. The focused WHIP Xcode test is not retried after MediaMTX is ready.

A tag-by-tag manifest search found that M137 and every published M144 Specs tag combine Swift tools 5.9 with newer PackageDescription visionOS constants, while M125.6422.09 is the newest release whose upstream manifest loads natively and exposes the required macOS audio-device API. `LocalCutPlatform` therefore depends on that exact upstream package and SwiftPM shares its normal caches across checkouts/worktrees, with no wrapper, script, committed binary, local symlink, or submodule. The full Xcode job covers the WebRTC path plus MediaMTX integration with a 300-second per-test timeout.

## Approach

1. **WebRTC stack.** Apple's `WKWebView` WebRTC implementation can't bridge to AVFoundation, and the official **GoogleWebRTC CocoaPods** binary is iOS-only with no macOS slice. The macOS-only `LocalCutPlatform` package target depends on the official `webrtc-sdk/Specs` **125.6422.09 (M125)** tag as an exact Swift package version; its manifest declares the XCFramework URL and checksum. SwiftPM owns download and caching, so worktrees need no special handling and a submodule adds no value. **BSD-3-Clause** licence (source and archive LICENSE; the Specs repository is MIT). We justify this AGENTS.md-significant addition because:
   - WHIP requires `RTCPeerConnection`; there is no Apple-native equivalent for SDP + ICE + DTLS-SRTP egress.
   - Apple's `WKWebView` WebRTC implementation cannot bridge to AVFoundation media pipelines.
   - All open-source alternatives (LiveKit-WebRTC, hand-rolled) wrap the same Google sources.
   - The dependency exists only in the macOS `LocalCutPlatform` graph; Linux builds only `LocalCutDomain` and needs no WebRTC substitute.
2. **WHIP HTTP client.** `WhipClient` — pure Swift over `URLSession` (no WebRTC dep). Methods: `publish(offerSdp)` returning `(resourceUrl, etag, iceServers, answerSdp)`, `patchIceRestart(resourceUrl, fragment, etag)`, `teardown(resourceUrl)`. The publish response's `ETag` is captured and every PATCH sends `If-Match: *` for RFC 9725 ICE restarts; strict servers return 412 Precondition Failed (or 428 Precondition Required) when restart preconditions are not met. PATCH bodies are ICE SDP fragments (`application/trickle-ice-sdpfrag`), not full session descriptions. The PATCH response's fresh `ETag` replaces the cached one for the next restart. Bearer tokens are injected on every verb but NEVER echoed in errors, logs, or diagnostics.
3. **Session orchestrator.** `WhipSession` actor owns the `RTCPeerConnection` (created via `RTCPeerConnectionFactory`), wires `sendonly` audio + video transceivers, applies WHIP-returned ICE servers to the live peer connection before setting the answer, applies codec preferences (H.264 baseline default, AV1 where the probe + endpoint allow), and drives the state machine:
   `idle → connecting → live → reconnecting → live / failed → ended`.
4. **Media taps.** Reuse Phase 45's `ProgramCompositor` output. The composited `CVPixelBuffer` feeds an `RTCVideoSource` via a custom `RTCVideoCapturer` subclass bound to the same `RTCPeerConnectionFactory` that owns the peer connection. **Audio is harder than the symmetric "use `RTCAudioSource`" claim might suggest:** the SDK does not expose a push-PCM method on `RTCAudioSource` / `RTCAudioTrack`. `webrtc-sdk` instead exposes an AVAudioEngine-based `RTCAudioDeviceModule` delegate. `AudioPublishBridge` buffers post-master-bus interleaved Float32 samples; its delegate replaces the physical input connection with an `AVAudioSourceNode`, and the engine requests samples at its native render cadence. The send-only session never routes publish audio into local playout.
5. **Reconnect policy.** 3 s grace on `disconnected`; a recovery to `connected` during grace cancels the pending reconnect. On `failed`, try ICE restart via PATCH (`application/trickle-ice-sdpfrag`) with the cached validator before full re-POST. On 405 / 501 / 412 / 428 / restart failure, DELETE the old resource and full re-POST as a new session (which yields a fresh ETag). Backoff 2 s → 4 s → 8 s → 16 s → 16 s, max 5 attempts. Terminal failure sends DELETE before clearing the resource URL.
6. **Encoder budget.** Acquire `.whipPublish` from `EncoderBudget` before opening the peer connection. Record + stream simultaneous use is offered only when both leases are available; otherwise an explicit "drop one to stream" message.
7. **Codec defaults.** H.264 constrained baseline (`42e029`) is the lowest-common-denominator; AV1 is hidden unless the local encode probe and endpoint type both allow it. Opus 128 kbps stereo for audio (WebRTC mandatory). The pinned M125 macOS sender API exposes bitrate limits but not deterministic GOP/keyframe interval control, so the keyframe interval UI is labelled best-effort.
8. **Settings + secrets.** Endpoint URL persists in app-scoped settings (NOT `ProjectDoc`). The bearer token defaults to in-memory **session-only** — typed once, never written to disk, dropped at app quit. Only after the user explicitly opts into "Remember on this device" does it move into a Keychain entry (`com.localcut.studio.publish.<endpoint>`); the opt-in dialog states plainly that the token then lives unencrypted in the Keychain like an OBS stream key. Bundle export structurally cannot leak the token because it's never in `ProjectDoc`.

## Trade-offs

- The community WebRTC XCFramework (`webrtc-sdk/Specs`) is an exception to "no third-party media libraries". We document this honestly: WHIP is otherwise impossible on macOS, and the project maintains a public WebRTC source fork and build pipeline.
- WebRTC's media engine does the encoding (not VideoToolbox directly) — we lose some control vs. our normal pipeline, but get reconnect + congestion control + DTLS-SRTP for free.
- RTMP-only platforms (YouTube, Douyin, Bilibili) are NOT supported directly; users run a WHIP → RTMP gateway (MediaMTX is the documented recipe). LocalCut never operates relay infra.

## Risks

- The community WebRTC XCFramework's API surface drifts with upstream WebRTC. Version 125.6422.09 is deliberately pinned; upgrades require manifest, header/import, audio-engine, WHIP, and MediaMTX validation.
- SwiftPM downloads a 60.2 MiB archive and extracts a roughly 142 MiB
  all-platform XCFramework. Only the roughly 39 MiB universal macOS framework
  is embedded in the current Debug app; release packaging must be re-measured
  whenever the pinned WebRTC version changes.
- Apple may ship a first-party `WebRTC` framework in a future macOS; we'd switch.

## Non-goals

- RTMP / SRT (no raw sockets via WHIP; SRT could be a separate spec via Apple's `NWConnection`).
- Simulcast / ABR ladders.
- Chat, overlays, alerts, platform APIs.
- Any hosted relay or account system.
