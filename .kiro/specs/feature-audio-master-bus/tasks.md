# Tasks: Audio Master Bus

> Status: **Implemented** in this branch.

## Engine

- [x] **T1.1** Add `AudioMasterBus.swift` with a `MainActor @Observable` class
  holding the live + offline `AVAudioEngine` graphs built from a shared
  description; expose `prepareLive` / `teardownLive` / `prepareOffline` /
  `renderOfflineBlock` / `teardownOffline` per the [design](./design.md#engine-types).
- [x] **T1.2** Add `TrackInput`, `VolumeEnvelope`, and `AudioMeterSnapshot`
  value types to `Models.swift`. `VolumeEnvelope` carries `fadeIn`, `fadeOut`,
  and additional `Ramp` entries; the type is `Sendable` and `Codable`.
- [x] **T1.3** Wire the master mixer tap on **both** live and offline graphs
  to compute peak + RMS per channel into an `OSAllocatedUnfairLock`-guarded
  `AudioMeterSnapshot` published through the `@Observable` accessor.
- [x] **T1.4** Engine lifecycle is idempotent — re-entrant start is a no-op,
  and a failed start tears down cleanly rather than leaking nodes.

## Composition integration

- [x] **T2.1** Extend `CompositionBuilder.swift` so audio mix parameters carry
  through the bus's master gain, per-track gain, and per-clip envelope
  on top of the existing transition crossfade ramps — using
  baseline-multiplied `setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)`
  so transition behaviour stays bit-identical at defaults.
- [x] **T2.2** Clamp `fadeIn` + `fadeOut` at render time: each fade ≤ clip
  duration; sum > clip duration ⇒ each = `clipDuration / 2`. `Ramp.range`
  clamps to the clip's effective range.

## EditorModel + Persistence

- [x] **T3.1** Add `audioBus: AudioMasterBus` to `EditorModel`; create it in
  `init()`, prepare the live graph lazily, tear down on session swap.
- [x] **T3.2** Add `setMasterGain(_:)`, `setTrackPan(_:trackID:)`,
  `setTrackGain(_:trackID:)`, `setClipVolumeEnvelope(_:clipID:)` on
  `EditorModel` (file: `EditorModel+AudioBus.swift`). Continuous gestures use
  `performCoalescedUndoable` with a stable target id; discrete edits use
  `performUndoable`.
- [x] **T3.3** Extend `ProjectState` (in `EditorModel+Persistence.swift`)
  with `masterGain`, `[TrackInputSnapshot]`, and per-clip volume envelopes
  so undo/redo restores them atomically.
- [x] **T3.4** Extend `ProjectDocument.swift` with `AudioBusDoc`,
  `TrackInputDoc`, and `VolumeEnvelopeDoc`. Lenient decoders match the
  existing pattern; legacy documents decode to defaults. Bump
  `currentSchemaVersion`.

## UI

- [x] **T4.1** Add `AudioInspectorView` rendered in `InspectorView` next to the
  `Captions` section, showing the master gain slider + the two-channel
  peak/RMS meter driven by the bus's `AudioMeterSnapshot`.
- [x] **T4.2** Add per-track pan/gain controls inside the existing track
  grouping; add per-clip fade-in / fade-out controls inside the clip section
  when an audio clip is selected.
- [x] **T4.3** All slider labels carry the parameter's current numeric value
  (dB for gain, ±1 for pan) for accessibility.

## Verification

- [x] **T5.1** Unit test: `setMasterGain` mutation is undoable and `undo()`
  restores the previous value (R6.1).
- [x] **T5.2** Unit test: a synthesised non-silent block fed through
  `renderOfflineBlock(into:)` produces a positive `meterSnapshot`; a silent
  block leaves it at zero (R6.2).
- [x] **T5.3** Unit test: the offline graph builds and renders a block
  without `setVoiceProcessingEnabled(_:)` having been touched (R6.3).
- [x] **T5.4** Unit test: `fadeIn + fadeOut > clipDuration` clamps each to
  `clipDuration / 2`; a `Ramp.range` past the clip end clamps to the clip
  end (R6.4).
- [x] **T5.5** Regression unit test: a project with defaults produces the
  same `AVMutableAudioMix.inputParameters` ramp set as before the bus existed,
  guarding the existing Phase 30 transition crossfade behaviour (R6.5).
- [x] **T5.6** `xcodebuild` (Debug, macOS) green; no test count regression.

## Cross-cutting

- [x] **T6.1** Update `.kiro/specs/ROADMAP.md`: move the Audio master bus row
  out of "Open infra" and into the "Existing spec" prerequisite-infrastructure
  table.
