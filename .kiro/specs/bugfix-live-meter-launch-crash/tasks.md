# Tasks: Live Meter Launch Crash

> Status: **Complete**.

## Implementation

- [x] **T1.1** Remove launch-time `prepareAudioMetering()` from
  `EditorView.onAppear`.
- [x] **T1.2** Add an explicit Audio inspector control to start live metering
  on demand.
- [x] **T1.3** Keep the idle/error state visible in the Audio inspector.
- [x] **T1.4** Remove the live-path `AVAudioEngine.prepare()` call that raised
  during graph initialisation.
- [x] **T1.5** Throw `LiveMeterError.unavailableOutputFormat` from
  `installLiveTapIfNeeded()` so a tap-install failure tears the engine down
  instead of leaving a running-but-untapped graph.
- [x] **T1.6** Share the `Live metering unavailable:` prefix between status bar
  and inspector, and clear it with `Live metering started.` on a successful
  retry.
- [x] **T1.7** Expose observable `AudioMasterBus.isOfflineMetering` and show the
  meter during offline export (`isLiveRunning || isOfflineMetering`).
- [x] **T1.8** (B5) Pre-flight `liveEngine.outputNode.inputFormat(forBus: 0)` in
  `prepareLive()` and throw `LiveMeterError.unavailableOutputFormat` before
  `start()`, closing the uncatchable-ObjC-exception path B1 left open.

## Verification

- [x] **V1** Full macOS `xcodebuild test` suite passes.
- [x] **V2** Rebuilt app launches to the editor window instead of the macOS
  reopen/crash loop.
- [x] **V3** Accessibility inspection confirms the Audio inspector reports
  `Live meter idle.` and exposes the `Start live audio meter` action.
- [x] **V4** (B5) `AudioMasterBus` logic tests pass (offline build, meter,
  gain), and a state-restoration relaunch reaches the editor window instead of
  trapping in `AVAudioEngineGraph::Initialize`.
