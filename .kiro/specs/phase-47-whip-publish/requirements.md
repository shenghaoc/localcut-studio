# Requirements: Phase 47 — WHIP Publish

## R1 — WHIP client

- **R1.1** RFC-9725 compliant: POST offer / accept answer + ICE servers via Link headers; PATCH ICE restart with `If-Match` ETag (§4.3.1); DELETE on stop.
- **R1.2** ETag from the publish response is cached; every PATCH sends it as `If-Match`. The PATCH response's new ETag replaces the cached one for the next restart. Missing / stale validators yield 412 or 428; on either, the reconnect controller falls back to full re-POST as a new session.
- **R1.3** Bearer token sent on every verb; never echoed in errors, logs, diagnostics, telemetry, or persisted alongside `ProjectDoc`.
- **R1.4** Error mapping returns typed results (`rejected-offer` | `auth` | `not-found` | `retryable`); `400` fails fast.

## R2 — Codec + bitrate

- **R2.1** H.264 constrained baseline (`42e029`) is the default codec; AV1 gated on (probe + endpoint).
- **R2.2** Opus 128 kbps stereo for audio.
- **R2.3** Defaults per endpoint type: Twitch / Cloudflare / MediaMTX / Custom; user-overridable within validated ranges.
- **R2.4** Keyframe-interval control is honoured where the platform allows; otherwise labelled best-effort.

## R3 — Capability gating

- **R3.1** GoogleWebRTC available + linked in the build → publish feature available; otherwise hidden.
- **R3.2** `EncoderBudget` lease for `.whipPublish` required before peer connection opens.
- **R3.3** Record + stream coexistence checks combined encoder count against the budget before start.

## R4 — Media taps

- **R4.1** Video source is the Phase 45 program output (`CVPixelBuffer` per output frame).
- **R4.2** Audio source is the master bus (post Phase 36 inserts) tapped via `AVAudioEngine`.
- **R4.3** Latest-frame-wins discipline on the video tap; one in-flight at a time; close-exactly-once.

## R5 — Reconnect

- **R5.1** 3 s grace on `disconnected`.
- **R5.2** Backoff 2 / 4 / 8 / 16 / 16 s; max 5 attempts; terminal `failed` after exhaustion.
- **R5.3** PATCH ICE restart (with `If-Match` ETag) attempted before full re-POST; 412 / 428 / 405 / 501 / restart failure all fall through to re-POST.
- **R5.4** State changes surfaced in `PublishState` for the UI.

## R6 — Settings + secrets

- **R6.1** Endpoint URL stored in app-scoped settings. Bearer token defaults to in-memory **session-only** (typed once, never written to disk, dropped at app quit). The token only moves to a Keychain entry (per endpoint) after the user explicitly opts into "Remember on this device" via R6.3.
- **R6.2** Bundle export structurally cannot include the publish store (test asserts).
- **R6.3** "Remember token on this device" toggle is opt-in; only then does the token persist in Keychain with plain copy explaining it lives unencrypted there like an OBS stream key.

## R7 — Verification

- **R7.1** Unit tests for `WhipClient` (mocked `URLSession`), reconnect state machine (fake timers), `EncoderBudget` integration.
- **R7.2** CI integration: publish to a MediaMTX container; assert ingest via the MediaMTX API; teardown sends DELETE.
- **R7.3** Bundle-exclusion test for the publish settings store.
- **R7.4** `xcodebuild` (Debug, macOS) green; no test count regression.
