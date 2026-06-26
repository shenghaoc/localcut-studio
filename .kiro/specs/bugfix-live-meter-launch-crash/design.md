# Design: Live Meter Launch Crash

This is a launch-stability hardening change for the audio master bus. It does
not change the offline export render path, the project document schema, or the
metered values themselves — it only changes **when** the live metering graph
starts and **how** its failures surface.

## Approach

Make live metering strictly opt-in and keep every failure recoverable.

1. **Remove launch-time startup.** `EditorView.onAppear` no longer calls
   `prepareAudioMetering()`. Opening a window therefore no longer depends on the
   current machine's audio-device graph.
2. **Explicit start.** The Audio inspector owns a **Start Live Meter** control
   that calls `EditorModel.prepareAudioMetering()` on demand.
3. **No pre-`start()` prepare.** The live path drops the extra
   `liveEngine.prepare()` call. `AVAudioEngine.prepare()` can raise an
   Objective-C exception during graph initialisation that Swift `do/catch`
   cannot recover from; letting `start()` do its own internal preparation keeps
   failures as ordinary thrown Swift errors that land in `lastStartError`.

   > **Correction (B5).** Step 3's premise is false: `start()` calls
   > `-[AVAudioEngine prepare]` internally, so dropping the *explicit* prepare
   > does **not** avoid the raise — `AVAudioEngineGraph::Initialize` still raises
   > the same uncatchable ObjC exception from inside `start()`. See *Pre-flight
   > guard (B5)* below.

4. **Pre-flight guard (B5).** Before calling `start()`, validate the output
   device: `liveEngine.outputNode.inputFormat(forBus: 0)` and throw
   `LiveMeterError.unavailableOutputFormat` when it reports a zero sample-rate /
   channel count. This converts the no-device / not-yet-ready case (the raise
   condition) into a catchable Swift error *before* `start()` runs, so the
   `do/catch` actually handles it. It is the same error B2 throws from the
   post-`start()` tap-install check, moved earlier so it can pre-empt the raise.

## Failure propagation

The live graph is brought up in two steps, and both must be recoverable:

```swift
func prepareLive() {
    guard !isLiveRunning else { return }
    do {
        // B5: pre-flight the output device so the no-format case throws a
        // catchable Swift error before start()/prepare() can raise an ObjC one.
        let deviceFormat = liveEngine.outputNode.inputFormat(forBus: 0)
        guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0 else {
            throw LiveMeterError.unavailableOutputFormat
        }
        try liveEngine.start()
        try installLiveTapIfNeeded()   // throws if no usable output format
        isLiveRunning = true
        lastStartError = nil
    } catch {
        lastStartError = error.localizedDescription
        teardownLive()                 // back to a clean, retryable state
    }
}
```

`installLiveTapIfNeeded()` throws `LiveMeterError.unavailableOutputFormat`
(a `private` `LocalizedError`) when the started engine's main mixer reports a
zero-channel / zero-sample-rate format — the no-audio-device / headless case.
Propagating instead of bailing silently means the bus never sits in a
running-but-untapped state (`isLiveRunning == true` while metering nothing); the
`catch` records the error and tears the engine down for a later retry.

## Status surfacing

`lastStartError` is the single source of truth for the failure string. To keep
the status bar and the inspector consistent:

- `EditorModel.prepareAudioMetering()` and `AudioInspectorView.audioMeterStatus`
  use the **same** `"Live metering unavailable: …"` prefix.
- On a successful (re)start, `prepareAudioMetering()` overwrites `statusMessage`
  (`"Live metering started."`) so the status bar and VoiceOver live region stop
  announcing a stale failure after recovery.

## Keeping the export meter visible

Live metering is now usually off, but offline export still publishes meter
snapshots through the sink registered in `EditorModel.init()`. To avoid the
idle/Start branch hiding the meter during exports, the bus exposes an observable
`isOfflineMetering` flag, mirrored on the main actor from
`setOfflineMeteringActive(_:)` (the `OSAllocatedUnfairLock` copy stays the
audio-thread source of truth). The inspector shows the live `MeterStrip` when
`isLiveRunning || isOfflineMetering`.

`setOfflineMeteringActive(_:)` is invoked through a `@MainActor`-typed activity
sink from `RenderQueue.runJob(id:)` (itself `@MainActor`), so the synchronous
`isOfflineMetering` write stays on the main actor — no cross-actor hop and no
`Task` indirection that would lag the meter's visibility behind the export.

## Scope

Touched: `AudioMasterBus`, `EditorModel.prepareAudioMetering`,
`AudioInspectorView`, `EditorView.onAppear`.

## Non-goals

- Wiring the live engine into the `AVPlayer` preview path — that remains
  Phase 36's job; this bus is still opt-in monitoring only.
- Changing offline export rendering or metered values.
- Bumping the project document schema. The on-disk shape is unchanged.
