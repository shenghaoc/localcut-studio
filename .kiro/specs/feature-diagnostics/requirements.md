# Requirements: Diagnostics Panel

> Status: **Proposed**. Prerequisite for Phase 37, 41, 46.

## R1 — Probes

- **R1.1** A `DiagnosticsAgent` samples once per second on its own timer; no probe runs more often than 1 Hz.
- **R1.2** CPU utilisation is derived from `task_info(mach_task_self_, TASK_THREAD_TIMES_INFO, ...)` deltas and normalised by `ProcessInfo.processInfo.activeProcessorCount` so 1.0 = "every core saturated".
- **R1.3** GPU utilisation is an `os_signpost`-equivalent estimate (best-effort) derived from the ratio of mean compositor render time to the project's frame duration, clamped to 0…1. The label discloses "GPU (est.)".
- **R1.4** The probe reports the active VideoToolbox decoder count as the number of video tracks in the current `AVMutableComposition` (the path that drives `AVAssetReaderTrackOutput`-equivalent decoder allocation in playback).
- **R1.5** The agent exposes `lastFrameTime` (most recent compositor render-time sample) and `p95RenderTime` (95th percentile over a rolling 256-sample ring).
- **R1.6** Frame drops come from `AVPlayerItem.accessLog().events.last?.numberOfDroppedVideoFrames`; the agent reports the delta since the previous tick.
- **R1.7** Every sample resolves to a non-NaN, finite value within 2 s of `start()`. A probe with no data yet (e.g. no preview running) reports 0, not NaN.

## R2 — Lifecycle

- **R2.1** The agent is owned by `EditorModel` and lives as long as the editor session.
- **R2.2** The 1 Hz timer is not scheduled until `start()` runs; `stop()` invalidates it so probes don't sample when the panel is hidden.
- **R2.3** Toggling `View ▸ Show Diagnostics` calls `start()` / `stop()` through `EditorModel.isDiagnosticsVisible`.
- **R2.4** Closing the editor (`EditorModel.deinit`) stops the agent.
- **R2.5** `start()` resets CPU calibration so the second tick after a fresh start reports a real delta, not a since-process-launch one.

## R3 — Cross-thread handoff

- **R3.1** `EffectCompositor.startRequest` calls `DiagnosticsBridge.shared.recordRenderTime(_:)` from its nonisolated render-queue context.
- **R3.2** `CompositionBuilder.build(...)` (or its caller in `EditorModel`) calls `DiagnosticsBridge.shared.setDecoderCount(_:)` after each successful build, with the video-track count of the built composition.
- **R3.3** The bridge is `Sendable`; all mutation is guarded by `OSAllocatedUnfairLock`. The agent reads it via `snapshot()` on the main actor.
- **R3.4** The render-time ring is bounded; oldest samples are evicted past capacity (256) so the bridge does not grow without bound.

## R4 — UI

- **R4.1** `DiagnosticsView` is a SwiftUI overlay anchored top-trailing on the editor window, ~280 pt wide.
- **R4.2** The background uses `NSVisualEffectView` (material `.hudWindow`, blending `.behindWindow`) so the panel sits over the preview without occluding it.
- **R4.3** One row per probe: CPU, GPU (est.), Decoders, Last render, P95 render, Frame drops.
- **R4.4** A `Path`-based sparkline of the most recent ≤60 render-time samples renders at the bottom. Empty state shows an em dash, not a flat zero line.
- **R4.5** `View ▸ Show Diagnostics` (⌥⌘D) toggles the panel; hidden by default.

## R5 — Logging

- **R5.1** Each tick writes one `os_log` event with subsystem `"com.localcutstudio.diagnostics"` and category `"sample"`.
- **R5.2** The event records all five numeric probes (CPU, GPU est., decoder count, last render time in ms, p95 render time in ms, dropped-frame delta) as structured fields.
- **R5.3** Logging happens only while the agent is running; pausing the agent silences the log.

## R6 — Test injection

- **R6.1** `DiagnosticsAgent` exposes `tickForTesting()` so tests can drive a sample synchronously instead of waiting on the timer.
- **R6.2** `DiagnosticsBridge` is reachable from the test bundle (via `DiagnosticsBridge.shared` plus a `reset()` method tests call between cases).
- **R6.3** A test can inject a fake slow render time via `recordRenderTime(_:)` and observe it reflected in `p95RenderTime` after a tick.

## R7 — Verification

- **R7.1** `xcodebuild` (Debug, macOS) green with no test count regression.
- **R7.2** Unit test: an agent that has been `start()`-ed for ≤ 2 s reports finite, non-NaN values for every probe.
- **R7.3** Unit test: after `stop()`, an additional second of wall-clock time produces no new samples (the agent's sample counter stays put).
- **R7.4** Unit test: injecting a slow render time and ticking pushes the agent's `p95RenderTime` above the slow-frame threshold.
- **R7.5** Unit test: render-time ring stays bounded at 256 entries even after thousands of `recordRenderTime` calls.
