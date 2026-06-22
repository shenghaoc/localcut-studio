# Design: Diagnostics Panel (P25 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 37 (frame interpolation), Phase 41 (capture engine), and Phase 46 (replay buffer).

## Goal

A single-pane perf panel that surfaces the four numbers the next batch of capture / interpolation / replay phases will need to reason about *before* they ship — CPU and GPU pressure, how many decoders the composition is keeping alive, how long the custom compositor is taking per frame, and whether the player is dropping frames at the output. Phase 37 needs to tell whether `VTFrameProcessor` is bottlenecked on the encoder or on its own session; Phase 41 needs to keep ScreenCaptureKit's input pipe under the wire; Phase 46 needs to verify that the replay buffer isn't pushing the GPU into thermal throttling. A first-class panel + structured log gives all three phases the same instrumentation surface instead of three ad-hoc print sites.

## Prerequisites

None on the codebase — diagnostics is a leaf piece. The Phase 30 PR (animated captions + caption tracks + keyframes + title raster) is the most recent merge; this spec follows the same three-document convention.

## Architecture

```
                       ┌──────────────────────────┐
                       │  EffectCompositor        │  (any AVFoundation thread)
                       │  startRequest(...)       │──┐
                       └──────────────────────────┘  │ recordRenderTime(seconds:)
                                                     ▼
                       ┌──────────────────────────┐
                       │  DiagnosticsBridge       │  (Sendable, OSAllocatedUnfairLock)
                       │  • render-time ring      │
                       │  • decoder count         │
                       │  • dropped-frame counter │
                       └──────────────────────────┘
                                ▲              ▲
                                │ snapshot()   │ setDecoderCount() / dropped
                                │              │
                       ┌──────────────────────────┐
                       │  DiagnosticsAgent        │  @Observable @MainActor
                       │  • 1 Hz timer            │
                       │  • CPU / GPU samples     │
                       │  • rolling p95           │
                       │  • os_log emission       │
                       └──────────────────────────┘
                                ▲
                                │ start() / stop()
                                │
                       ┌──────────────────────────┐
                       │  EditorModel             │
                       │  • isDiagnosticsVisible  │
                       │  • diagnostics: Agent    │
                       └──────────────────────────┘
                                ▲
                                │ binding
                                │
                       ┌──────────────────────────┐
                       │  DiagnosticsView         │
                       │  + NSVisualEffectView bg │
                       └──────────────────────────┘
```

The bridge is the **only** cross-thread component. `EffectCompositor.startRequest` is `nonisolated` and runs on AVFoundation's render queue; the agent is `@MainActor`. Going through a `Sendable` bridge keeps the cross-thread surface to two method calls — `recordRenderTime(_:)` and `snapshot()` — and avoids actor hops on the hot path.

## Probes

Five probes resolve once per second on the agent's tick.

### CPU utilisation

`proc_pidinfo(getpid(), PROC_PIDTASKINFO, ...)` returns the task's `pti_total_user` and `pti_total_system` in nanoseconds, both of which cover **live and terminated** threads in a single call. The agent divides the delta by wall-clock seconds since the last tick and normalises by `ProcessInfo.processInfo.activeProcessorCount` so `1.0` means every core is saturated. No entitlements (own-process pid), no private framework. The first tick after `start()` is the calibration — utilisation reads as `0` until the second tick when a delta exists.

We picked libproc over Mach's `task_info` for two reasons. First, the Mach interface splits the same number across `TASK_THREAD_TIMES_INFO` (live threads) and `MACH_TASK_BASIC_INFO` (terminated threads), so querying only one half undercounts whichever side the workload happens to land on — short-lived background tasks finish quickly and show up only in basic-info; long-lived render queues show up only in thread-times. Summing both would also work, but second: macOS 26's SDK marks `MACH_TASK_BASIC_INFO_COUNT` unavailable ("structure not supported"), so the two-step Mach query won't compile. `proc_pidinfo` is the clean way to get the right number without the deprecated Mach surface.

### GPU utilisation (best-effort proxy)

macOS 26 has no public entitlement-free GPU counter accessor (`IOReport` requires `com.apple.private.iokit.ioreporting`; `MTLCounterSet` requires per-encoder counter buffers we don't allocate). The agent estimates GPU pressure as `mean(renderTime) / frameDuration` clamped to 0…1 — the proportion of frame budget the compositor (Core Image → Metal under the hood) is consuming. The bridge also exposes a monotonic `totalFrameCount`; if no new frames landed during a tick (player paused, no composition), the agent reports GPU = 0 instead of dragging the historical mean off the ring. The label in the panel reads "GPU (est.)" with a help tooltip explaining the heuristic. When macOS 27 ships a public counter API the probe swaps in without changing the bridge contract.

### Active decoder count

The composition's `AVAssetTrack` count for `.video` is a clean proxy for the active VideoToolbox decoder count: each composition track that backs an actual source asset gets its own decoder in the playback pipeline. `EditorModel.rebuild()` already produces the `BuiltComposition`, so it writes `DiagnosticsBridge.shared.setDecoderCount(built.composition.tracks(withMediaType: .video).count)` after every successful build. The agent reads it on tick — no need to introspect the live player.

### Render-time p95

`EffectCompositor.startRequest` brackets its body with `CFAbsoluteTimeGetCurrent()` and writes the delta into `DiagnosticsBridge.recordRenderTime(_:)`. The bridge keeps a 256-sample ring. On tick the agent computes:

- `lastFrameTime` — most recent sample
- `p95RenderTime` — 95th percentile over the ring

256 samples ≈ ~8.5 s of preview at 30 fps — long enough to smooth single-frame spikes, short enough that a slow effect that landed 30 s ago doesn't drag the metric.

### Frame drops

`AVPlayerItem.accessLog().events.last?.numberOfDroppedVideoFrames` is monotonic across the player item's life and works without entitlements on macOS 26. The agent reads it on tick and reports the delta since the previous tick.

The task brief mentions `outputItemTimeForHostTime` as a possible signal — that's the API for `AVPlayerItemVideoOutput`, which the editor doesn't attach. Sticking to the access log keeps the probe in-band with what the current player setup actually exposes and avoids adding a video output just for diagnostics.

## Lifecycle

`EditorModel.diagnostics: DiagnosticsAgent` is created in the editor's `init` and lives as long as the editor session. The 1 Hz `Timer` is **not** scheduled until `start()` runs, and is invalidated by `stop()` so the timer thread sleeps when the panel is hidden — the panel's `View ▸ Show Diagnostics` toggle drives `start()` / `stop()` through `EditorModel.isDiagnosticsVisible`. When the editor tears down, the agent's `deinit` invalidates the timer and closes the bridge's hot-path gate — done in the agent rather than `EditorModel.deinit` because `stop()` is MainActor-isolated (it writes `isRunning`) and Swift 6 makes a `@MainActor` class's `deinit` nonisolated by default, so the agent owning its own teardown keeps the editor's deinit free of isolation gymnastics.

`start()` resets only the transient state: CPU calibration baseline (so a stale "user_time" delta doesn't show as a spike on the second tick), the render-time ring, and the monotonic frame counter. It deliberately **preserves** the bridge's decoder count and dropped-frame counter, both of which were populated by the editor / player independently of the panel — wiping them would leave the Decoders row stuck at zero until the next composition edit, since the visibility toggle doesn't schedule a rebuild. It also seeds `previousDroppedFrames` from the live counter at start time so historical drops that piled up before the panel opened don't appear as a single massive spike on the first tick.

### Hot-path gate

The bridge exposes a separate `isEnabled` flag (its own `OSAllocatedUnfairLock` so the compositor doesn't contend on the data lock). `EffectCompositor.startRequest` checks the flag **before** taking a timestamp; when the flag is false, the entire timing path is skipped and the compositor pays nothing more than a single uncontended lock acquire per frame. `start()` opens the gate; `stop()` closes it. Tests bypass the gate by calling `recordRenderTime(_:)` directly so they can inject samples without flipping the flag.

### Empty composition

When `EditorModel.rebuild()` produces no composition (last clip deleted, empty project opened), it calls `clearRenderSamples()` in addition to setting decoder count to 0. Otherwise no compositor request would ever run, the ring would freeze on its last contents, and the panel would keep reporting stale GPU / last / p95 numbers indefinitely.

## UI

`DiagnosticsView` is a SwiftUI overlay anchored top-trailing on the editor, ~280 pt wide. The background is an `NSVisualEffectView` wrapped through `NSViewRepresentable` (material `.hudWindow`, blending `.behindWindow`) so it sits on top of the preview without occluding it like a solid panel would.

Layout: one `LabeledContent` row per probe, with a 60-sample `Path`-based sparkline of render times at the bottom. The sparkline uses `Path.addLines(_:)` over normalised points rather than the `Charts` framework so the panel adds zero weight to the linker. The y-axis is floored at the 60 fps budget (~16.6 ms) so a sub-millisecond fluctuation doesn't get stretched into a misleading peak — a real spike past the budget pushes the scale up as before.

The View menu gains one item — `View ▸ Show Diagnostics` (⌥⌘D) — that toggles `model.isDiagnosticsVisible`. Hidden is the default.

## Logging

The agent writes one structured `os_log` event per tick:

```
[com.localcutstudio.diagnostics / sample]
  cpu=0.18 gpu_est=0.42 decoders=3 last=12.4ms p95=21.7ms drops=0
```

The subsystem is `com.localcutstudio.diagnostics`; the category is `sample`. Console.app filters cleanly on subsystem; the same numbers show in the panel and in the log so a developer can compare against system traces without rerunning the app.

## Test injection

The agent exposes `tickForTesting()` so a test can drive a sample synchronously without waiting on the timer. The bridge exposes `recordRenderTime(_:)` (ungated — the hot-path gate lives in the compositor, not the bridge) so a test can inject a slow frame, tick, and assert `p95RenderTime` updates. `reset()` clears every field for a clean baseline between cases; `clearRenderSamples()` exists as the scoped variant the agent + editor use in production. CPU calibration is bootstrappable through a single optional `now: () -> CFAbsoluteTime` injection that defaults to `CFAbsoluteTimeGetCurrent`, so a test can synthesise a known wall-clock delta.

## Trade-offs

- **One bridge, one agent.** A bag-of-singletons would be quicker to wire but leaves no place to swap in a stub for tests; the bridge / agent split mirrors the rest of the editor's "value-typed snapshot, observable consumer" pattern.
- **Render-time ring at 256 samples.** A windowed ring covers the common case (single slow frame should dominate p95 within a few ticks) without paying for a percent-of-history estimator. If a future phase needs minute-scale rolling stats, the ring grows behind the same `snapshot()` shape.
- **GPU proxy now, real counters when macOS 27 lands.** The alternative — defer the panel until macOS 27 — leaves Phase 37 / 41 / 46 to instrument themselves locally, which we already declined when picking up P25 from the roadmap.
- **Access log over `outputItemTimeForHostTime`.** Adding a video output just to count drops would change the player's pixel-buffer flow and might mask the very drops we're trying to count; the access log reports drops the player already noticed.
- **Panel as overlay, not split-pane.** Diagnostics is opt-in and ephemeral; keeping it out of the `HSplitView` means no layout reflow when it toggles, and it doesn't trade panel real estate with the inspector.

## Risks

- **Timer cost.** A 1 Hz timer with five probe reads is cheap; we still leave it dormant when the panel is hidden so a long-running export doesn't pay the cost.
- **GPU proxy misreads.** If the user disables preview entirely (no `currentItem`), `renderTime` is empty and the GPU number stays at zero — that's *correct* (no GPU work) even though it looks like the probe is broken. The panel renders a `—` (em dash) when no samples have been collected so an empty state doesn't look like a stuck zero.
- **Log volume.** One line per second per editor session; bounded by the panel staying open. Console.app can drop without affecting the panel.

## Non-goals

- Per-frame tracing (Instruments owns that).
- Disk / network IO probes (out of scope for the phases this unblocks).
- Historical persistence across sessions — every panel session starts cold.
- Counter buffers via `MTLCounterSampleBuffer` (deferred until the agent has a real GPU number to compare against on macOS 27).
- A separate "diagnostics" window — the overlay panel is enough; a torn-off window can come later.
