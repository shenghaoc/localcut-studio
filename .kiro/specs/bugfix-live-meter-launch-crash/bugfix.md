# Bugfix: Live Meter Launch Crash

> Status: **Complete**.

Pre-existing launch-stability bug found while visually verifying PR #48. This
is unrelated to PR #48's SwiftUI design/accessibility scope: the app could crash
before any imported media or design-specific interaction because the editor
window automatically started the live audio metering graph on appearance.

## Bugs

### B1 - Editor launch can crash while auto-starting live metering

Launching a debug build on macOS 27 produced the standard macOS reopen warning.
The latest crash report showed `EXC_BREAKPOINT` / `SIGTRAP` from
`AVAudioEngineGraph::Initialize` while the app was opening its initial SwiftUI
window:

- `AudioMasterBus.prepareLive()`
- `EditorModel.prepareAudioMetering()`
- `EditorView.onAppear`

The live audio graph is not yet wired into preview playback; it exists for
opt-in monitoring and future capture/voice-cleanup work. Starting it
automatically on every window open makes ordinary app launch depend on the
current machine's audio-device graph. `AVAudioEngine.prepare()` can raise an
Objective-C exception during graph initialisation, which Swift `do/catch` cannot
recover from.

- **Fix**: Stop auto-starting live metering from `EditorView.onAppear`. The
  Audio inspector now shows an idle state and an explicit **Start Live Meter**
  control when the user wants to start the live graph.
- **Fix**: Remove the extra `liveEngine.prepare()` call from the live path so
  explicit starts go straight through `start()`, where Swift can still surface
  normal thrown errors through `lastStartError`.
- **Impact**: Opening the app no longer depends on an unwired hardware audio
  graph. If live metering cannot start later, the inspector reports the failure
  instead of crashing at launch.
