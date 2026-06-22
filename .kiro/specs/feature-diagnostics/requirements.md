# Requirements: Diagnostics Panel

> Status: **Proposed**. Prerequisite for Phase 37, 41, 46.

## R1 — Probes

- **R1.1** A `DiagnosticsAgent` samples once per second on its own timer; no probe runs more often than 1 Hz.
- **R1.2** CPU utilisation is derived from `proc_pidinfo(getpid(), PROC_PIDTASKINFO, ...)` deltas — `pti_total_user + pti_total_system` covers live and terminated threads in a single libproc call — and normalised by `ProcessInfo.processInfo.activeProcessorCount` so 1.0 = "every core saturated". The two-step Mach path (`TASK_THREAD_TIMES_INFO` + `MACH_TASK_BASIC_INFO`) would also work, but macOS 26 marks `MACH_TASK_BASIC_INFO_COUNT` unavailable, so libproc is the path we ship.
- **R1.3** GPU utilisation is a best-effort estimate derived from the ratio of mean compositor render time to the project's frame duration, clamped to 0…1. The label discloses "GPU (est.)". The metric resolves to 0 whenever no new frames arrived during the previous tick (player paused, no composition) — the historical ring must not drag the value off zero when the GPU isn't actually doing work.
- **R1.4** The probe reports the active VideoToolbox decoder count as the number of video tracks in the current `AVMutableComposition` (the path that drives `AVAssetReaderTrackOutput`-equivalent decoder allocation in playback).
- **R1.5** The agent exposes `lastFrameTime` (most recent compositor render-time sample) and `p95RenderTime` (95th percentile over a rolling 256-sample ring).
- **R1.6** Frame drops come from `AVPlayerItem.accessLog().events.last?.numberOfDroppedVideoFrames`; the agent reports the delta since the previous tick. The drop baseline is seeded from the live counter on `start()` so historical drops do not appear as a single first-tick spike.
- **R1.7** Every sample resolves to a non-NaN, finite value within 2 s of `start()`. A probe with no data yet (e.g. no preview running) reports 0, not NaN.

## R2 — Lifecycle

- **R2.1** The agent is owned by `EditorModel` and lives as long as the editor session.
- **R2.2** The 1 Hz timer is not scheduled until `start()` runs; `stop()` invalidates it so probes don't sample when the panel is hidden.
- **R2.3** Toggling `View ▸ Show Diagnostics` calls `start()` / `stop()` through `EditorModel.isDiagnosticsVisible`.
- **R2.4** Closing the editor stops the agent: the agent's `deinit` invalidates the timer and closes the bridge gate, so a torn-down editor session doesn't leave the compositor recording into the bridge or the timer wakeup scheduled.
- **R2.5** `start()` resets CPU calibration so the second tick after a fresh start reports a real delta, not a since-process-launch one.
- **R2.6** `start()` preserves the bridge's decoder count (populated by the editor's most recent rebuild, independent of the panel's lifecycle) and seeds the drop baseline from the live counter; only render-related transient state is wiped.
- **R2.7** When `EditorModel.rebuild()` produces no composition, the bridge's render samples are cleared in addition to setting decoder count to 0 — otherwise GPU / last / p95 would report stale numbers indefinitely.

## R3 — Cross-thread handoff

- **R3.1** `EffectCompositor.startRequest` checks `DiagnosticsBridge.shared.isEnabled` **before** taking a timestamp; only when the gate is open does it record a per-frame render time via `recordRenderTime(_:)`. A hidden panel must not impose timestamp + lock + ring-buffer cost on every preview / export frame.
- **R3.2** `CompositionBuilder.build(...)` (or its caller in `EditorModel`) calls `DiagnosticsBridge.shared.setDecoderCount(_:)` after each successful build, with the video-track count of the built composition.
- **R3.3** The bridge is `Sendable`; all mutation is guarded by `OSAllocatedUnfairLock`. The `isEnabled` flag uses a separate lock so the hot-path read does not contend on the data lock. The agent reads the data via `snapshot()` on the main actor.
- **R3.4** The render-time ring is bounded; oldest samples are evicted past capacity (256) so the bridge does not grow without bound.
- **R3.5** The bridge exposes a monotonic `totalFrameCount` (bumped on every `recordRenderTime`) so the agent can detect an idle tick and zero the GPU estimate.

## R4 — UI

- **R4.1** `DiagnosticsView` is a SwiftUI overlay anchored top-trailing on the editor window, ~280 pt wide.
- **R4.2** The background uses `NSVisualEffectView` (material `.hudWindow`, blending `.behindWindow`) so the panel sits over the preview without occluding it.
- **R4.3** One row per probe: CPU, GPU (est.), Decoders, Last render, P95 render, Frame drops.
- **R4.4** A `Path`-based sparkline of the most recent ≤60 render-time samples renders at the bottom. The y-axis is floored at the 60 fps budget (16.6 ms) so sub-millisecond fluctuations don't stretch into misleading peaks. Empty state shows an em dash, not a flat zero line.
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
- **R7.6** Unit test: a decoder count published before `start()` survives `start()` (R2.6).
- **R7.7** Unit test: GPU estimate drops to 0 when no new frames arrive during a tick (R1.3).
- **R7.8** Unit test: `clearRenderSamples()` wipes the ring + frame counter but preserves decoder count and drops (R2.6).
- **R7.9** Unit test: `DiagnosticsBridge.shared.isEnabled` tracks the agent's `start()` / `stop()` (R3.1).
