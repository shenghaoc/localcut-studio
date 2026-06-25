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

## Verification

- [x] **V1** Full macOS `xcodebuild test` suite passes.
- [x] **V2** Rebuilt app launches to the editor window instead of the macOS
  reopen/crash loop.
- [x] **V3** Accessibility inspection confirms the Audio inspector reports
  `Live meter idle.` and exposes the `Start live audio meter` action.
