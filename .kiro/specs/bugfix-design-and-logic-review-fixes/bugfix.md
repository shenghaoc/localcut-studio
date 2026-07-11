# Bugfix: Design and Logic Review Fixes

> Status: **Complete and verified**. Target branch:
> `fix/design-and-logic-issues`.

## Context

The audit found correctness and UX defects across previously implemented
features. The root causes were stale derived state, incomplete edge-case guards,
preview/export ownership drift, best-effort cache fallback violating its memory
contract, and inspector predicates that hid actionable tools. Follow-up review
also found route-transition defects introduced while correcting loudness
ownership. Final-gate verification exposed a CI harness defect: disabling all
code signing leaves the macOS UI-test runner unsigned, so Gatekeeper terminates
it before XCTest can bootstrap.

## Expected behavior and fixes

### Timeline, selection, and persistence

- Beat cutting ignores zero-duration candidates without advancing the active
  segment, rejects a one-piece no-op before registering undo, and keeps retime
  and source offsets coherent.
- Selection remains mutually exclusive and undo/redo restores media, callout,
  clip, and transition selection consistently.
- The O(1) clip index refreshes on scheduled/direct rebuild and state restore.
  Indexed reads validate the clip ID and fall back to a scan during the narrow
  window after a direct track mutation, so stale offsets cannot return another
  clip.
- Layout tracks and overlay keyframes round-trip through the document schema.

### Audio and render parity

- Loudness has one owner: `AVAudioMix` for loudness-only compositions and
  `VoiceCleanupDSP` for DSP-active compositions. Measurement excludes previous
  gain.
- Any active loudness gain-value change rebuilds the composition audio mix.
  Switching preview routes cancels stale scheduled DSP audio and restores mixer
  unity before the next route starts.
- Export/writer failures remove partial output, and queue progress remains
  monotonic across completed, cancelled, and failed jobs.

### Effects, overlays, and cache budgets

- Caption/keyframe mutation preserves Bezier handles and clamps retimed word
  timing. Overlay position, scale, rotation, and opacity keyframes persist and
  evaluate in both preview and export.
- Look controls report playhead-interpolated values; preset import/export and
  LUT-sidecar paths retain sandbox and error-reporting guarantees.
- `RenderCache` drops an evicted frame when disk spill fails instead of
  reinserting it, keeping the memory byte budget authoritative.

### UX and accessibility

- Screencast and tutorial sections remain mounted for discoverability. Their
  individual controls disable or explain unavailable inputs, while generic
  markers and audio-bearing video clips keep their relevant workflows usable.
- Icon-only controls retain labels/help, the speed curve exposes a VoiceOver
  adjustable action, and queue/export failure and cancellation states use
  actionable status text.
- Focused state containers keep new feature state out of the central
  `EditorModel`; no parallel render, persistence, or selection system is added.

### CI harness

- The full-suite, non-WebRTC, and MediaMTX Xcode invocations keep Xcode's
  default local ad hoc signing enabled. This requires no developer identity,
  lets the macOS UI-test runner pass Gatekeeper, and preserves the test host's
  sandbox network entitlement for localhost integration. This describes the
  historical harness; the later required-WebRTC platform extraction removed
  the non-WebRTC lane.
- The MediaMTX script owns a short-lived marker in the ignored `.build`
  directory. Swift Testing discovery reads that marker, avoiding Xcode 27's
  filtering of parent-process environment variables and ensuring the required
  integration cases execute instead of silently appearing as disabled.
- MediaMTX probes the pinned v1.19 global-config API and publishes through the
  product's `/stream/whip` endpoint; teardown assertions inspect the matching
  `stream` path rather than an unrelated stale test path.
- The WebRTC downloader's generated license copy remains a local dependency
  artifact and is ignored by Git.

## Verification path

- Focused app regressions cover beat no-ops, active loudness gain rebuilds,
  stale clip-index offsets, tutorial-input reachability, overlay persistence,
  and failed cache spill memory bounds.
- `swift test --package-path Packages/LocalCutCore` covers shared beat,
  keyframe, voice-cleanup, capture, capability, and model changes.
- macOS `xcodebuild test` is the required final compile and app-suite gate;
  the recorder UI test must launch and complete under ad hoc signing.
- The MediaMTX integration command must report both WHIP cases as passed, not
  merely a successful Xcode invocation with disabled tests.
