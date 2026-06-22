# Tasks: Diagnostics Panel

> Status: **Implemented** in this branch.

## Engine

- [x] **T1.1** `DiagnosticsBridge` (`DiagnosticsBridge.swift`) — `Sendable` collector with `OSAllocatedUnfairLock`-guarded render-time ring (cap = 256), decoder count, and frame-drop counter; `snapshot()` returns a `Sendable` value.
- [x] **T1.2** `DiagnosticsAgent` (`DiagnosticsAgent.swift`) — `@Observable @MainActor`; 1 Hz `Timer`; CPU via `task_info(mach_task_self_, TASK_THREAD_TIMES_INFO)`; GPU as `mean(render) / frameDuration` proxy; p95 over the ring; tick emits an `os_log` event with subsystem `"com.localcutstudio.diagnostics"`.
- [x] **T1.3** Probe lifetime: `EditorModel` owns the agent; `View ▸ Show Diagnostics` toggle drives `start()` / `stop()`; `EditorModel.deinit` calls `stop()`.
- [x] **T1.4** `EffectCompositor.startRequest` writes per-frame render times via `DiagnosticsBridge.shared.recordRenderTime(_:)`.
- [x] **T1.5** `EditorModel.rebuild()` publishes the built composition's video-track count via `DiagnosticsBridge.shared.setDecoderCount(_:)`.

## UI

- [x] **T2.1** `DiagnosticsView` (`DiagnosticsView.swift`) — six `LabeledContent` rows + a `Path` sparkline; ~280 pt wide.
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
- [x] **V5** `xcodebuild` (Debug, macOS) green; no test count regression.

## ROADMAP

- [x] **R1** `.kiro/specs/ROADMAP.md` — move the **Diagnostics (P25)** row out of the "Open infra" table into the "Existing spec" table; first-needed-by phases stay 37, 41, 46.
