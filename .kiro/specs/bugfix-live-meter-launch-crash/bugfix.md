# Bugfix: Live Meter Launch Crash

> Status: **Complete** — reopened and extended by **B5** (the original B1 fix
> was incomplete: `start()` still raised the same uncatchable exception).

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

### B2 - Live tap install could fail silently

If `liveEngine.start()` succeeded but the main mixer reported no usable output
format, `installLiveTapIfNeeded()` returned early without installing a tap. The
bus was then left running with `isLiveRunning == true` but no meter tap — a
silent meter with no error feedback.

- **Fix**: `installLiveTapIfNeeded()` now throws
  `LiveMeterError.unavailableOutputFormat` (a `private` `LocalizedError`), and
  `prepareLive()` calls it with `try`. The failure flows into the existing
  `catch`, records `lastStartError`, and tears the engine down for a clean
  retry.

### B3 - Status message inconsistent / stale

The status bar and the inspector described the same failure with different
prefixes ("Audio metering" vs. "Live metering"), and a successful retry left the
old "unavailable" message announced by the status bar and VoiceOver live region.

- **Fix**: Share the `"Live metering unavailable: …"` prefix between
  `EditorModel.prepareAudioMetering()` and `AudioInspectorView.audioMeterStatus`,
  and overwrite `statusMessage` with `"Live metering started."` on a successful
  (re)start.

### B4 - Export meter hidden once live metering became opt-in

With auto-start removed, normal sessions run with `isLiveRunning == false`, but
offline export still publishes meter snapshots through the sink registered in
`EditorModel.init()`. The new idle/Start branch hid the `MeterStrip` during
exports unless the user had manually started the unrelated live graph first.

- **Fix**: Add an observable `AudioMasterBus.isOfflineMetering` flag (mirrored on
  the main actor from `setOfflineMeteringActive(_:)`) and show the `MeterStrip`
  when `isLiveRunning || isOfflineMetering`.

### B5 - `start()` still raised an ObjC exception the `do/catch` could not catch

The B1 fix removed the explicit `prepare()` call on the assumption that letting
`start()` self-prepare would keep failures as ordinary thrown Swift errors (see
`design.md` → *No pre-`start()` prepare*). **That assumption was wrong.**
`AVAudioEngine.start()` calls `-[AVAudioEngine prepare]` internally, and
`AVAudioEngineGraph::Initialize` still *raises an Objective-C exception*
("required condition is false: IsFormatSampleRateAndChannelCountValid") when the
output device has no valid format — which a Swift `do/catch` cannot intercept.

A debug build therefore still crashed (`EXC_BREAKPOINT` / `SIGTRAP`) — this time
during AppKit window **state-restoration** at launch (a saved window restoring
the panel that starts the live graph), before any media import. The B2 format
check ran only *after* `start()`, so it could never prevent the raise.

- **Fix**: Pre-flight the output device in `prepareLive()` —
  `liveEngine.outputNode.outputFormat(forBus: 0)` — and throw the existing
  `LiveMeterError.unavailableOutputFormat` (a catchable Swift error) **before**
  reaching the raising `start()` / `prepare()`. The no-device / not-yet-ready
  case now tears the engine down cleanly instead of trapping the whole app.
- **Impact**: Closes the launch-crash path B1 only partially addressed. Live
  metering start is safe on a headless box and during state-restoration.
- **Repro note**: only surfaces on a state-restoration relaunch (saved window
  restored), not on a cold `Run` from Xcode — reproduce via restoration.
