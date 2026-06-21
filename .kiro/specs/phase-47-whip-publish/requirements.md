# Requirements: Phase 47 — WHIP Publish

## R1 — WHIP client

- **R1.1** RFC-9725 compliant: POST offer / accept answer + ICE servers via Link headers; PATCH ICE restart; DELETE on stop.
- **R1.2** Bearer token sent on every verb; never echoed in errors, logs, diagnostics, telemetry, or persisted alongside `ProjectDoc`.
- **R1.3** Error mapping returns typed results (`rejected-offer` | `auth` | `not-found` | `retryable`); `400` fails fast.

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
- **R5.3** PATCH ICE restart attempted before full re-POST.
- **R5.4** State changes surfaced in `PublishState` for the UI.

## R6 — Settings + secrets

- **R6.1** Endpoint URL stored in app-scoped settings; token in keychain (per endpoint).
- **R6.2** Bundle export structurally cannot include the publish store (test asserts).
- **R6.3** "Remember token on this device" toggle stores it in Keychain; plain copy that it's a device-scoped secret.

## R7 — Verification

- **R7.1** Unit tests for `WhipClient` (mocked `URLSession`), reconnect state machine (fake timers), `EncoderBudget` integration.
- **R7.2** CI integration: publish to a MediaMTX container; assert ingest via the MediaMTX API; teardown sends DELETE.
- **R7.3** Bundle-exclusion test for the publish settings store.
- **R7.4** `xcodebuild` (Debug, macOS) green; no test count regression.
