# Tasks: Diagnostics Panel

> Status: **Implemented** in this branch.

## Engine

- [x] **T1.1** `DiagnosticsBridge` (`DiagnosticsBridge.swift`) — `Sendable` collector with `OSAllocatedUnfairLock`-guarded render-time ring (cap = 256), decoder count, frame-drop counter, and a monotonic `totalFrameCount`; `snapshot()` returns a `Sendable` value. Separate `isEnabled` lock so the compositor's hot-path read doesn't contend on the data lock. `reset()` clears everything (tests); `clearRenderSamples()` is the scoped variant production code uses.
- [x] **T1.2** `DiagnosticsAgent` (`DiagnosticsAgent.swift`) — `@Observable @MainActor`; 1 Hz `Timer`; CPU summed from `TASK_THREAD_TIMES_INFO` (live) + `MACH_TASK_BASIC_INFO` (terminated); GPU as `mean(render) / frameDuration` proxy, zeroed on idle ticks via `totalFrameCount` delta; p95 over the ring; tick emits an `os_log` event with subsystem `"com.localcutstudio.diagnostics"`.
- [x] **T1.3** Probe lifetime: `EditorModel` owns the agent; `View ▸ Show Diagnostics` toggle drives `start()` / `stop()`; `EditorModel.deinit` calls `stop()`. `start()` preserves decoder count, seeds the drop baseline from `droppedFramesProvider()`, opens the bridge gate; `stop()` closes the gate.
- [x] **T1.4** `EffectCompositor.startRequest` checks `DiagnosticsBridge.shared.isEnabled` before taking a timestamp — a hidden panel pays no per-frame cost beyond a single uncontended lock acquire.
- [x] **T1.5** `EditorModel.rebuild()` publishes the built composition's video-track count via `DiagnosticsBridge.shared.setDecoderCount(_:)`; the empty-composition branch also calls `clearRenderSamples()` so stale ring data doesn't haunt the panel.

## UI

- [x] **T2.1** `DiagnosticsView` (`DiagnosticsView.swift`) — six `LabeledContent` rows + a `Path` sparkline; ~280 pt wide. The sparkline y-axis is floored at 16.6 ms (60 fps budget) so sub-ms noise doesn't fill the panel.
- [x] **T2.2** `NSVisualEffectView` (`.hudWindow` material, `.behindWindow` blending) wrapped through `NSViewRepresentable` as the panel background.
- [x] **T2.3** `View ▸ Show Diagnostics` command (⌥⌘D) toggling `EditorModel.isDiagnosticsVisible`; default hidden.
- [x] **T2.4** Overlay attached top-trailing on `EditorView` so it doesn't reshape the timeline / inspector layout.

## Test injection

- [x] **T3.1** `DiagnosticsAgent.tickForTesting()` drives one sample synchronously.
- [x] **T3.2** `DiagnosticsBridge.reset()` for tests to clear shared state between cases.

## Verification

- [x] **V1** Unit test: probes resolve to non-NaN samples within 2 s of `start()`.
- [x] **V2** Unit test: pausing the agent stops sampling (`sampleCount` stays put across a 1 s wait).
- [x] **V3** Unit test: render-time p95 reflects an injected slow frame.
- [x] **V4** Unit test: render-time ring stays bounded at 256 entries past the cap.
- [x] **V5** Unit test: decoder count published before `start()` survives the start reset (Codex P1 regression).
- [x] **V6** Unit test: GPU estimate drops to 0 when no new frames arrive during a tick (Gemini medium regression).
- [x] **V7** Unit test: drop baseline seeded from live counter — first tick after `start()` reports 0 drops, not historical (Codex P2 regression).
- [x] **V8** Unit test: bridge's `isEnabled` flag tracks `start()` / `stop()` (Codex P2 regression).
- [x] **V9** Unit test: `clearRenderSamples()` wipes the ring + frame counter but preserves decoder count and drops.
- [x] **V10** `xcodebuild` (Debug, macOS) green; no test count regression.

## ROADMAP

- [x] **R1** `.kiro/specs/ROADMAP.md` — move the **Diagnostics (P25)** row out of the "Open infra" table into the "Existing spec" table; first-needed-by phases stay 37, 41, 46.
