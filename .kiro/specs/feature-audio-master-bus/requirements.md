# Requirements: Audio Master Bus

## R1 — Engine

- **R1.1** An `AudioMasterBus` exists at `EditorModel.audioBus` and is built on
  `AVAudioEngine`, with one **live** engine driving the system default device
  for preview and a **separate offline** engine in `manualRenderingMode = .offline`
  for export.
- **R1.2** The two engines share a single graph **description** but instantiate
  independent `AVAudioNode` graphs. `AVAudioInputNode.setVoiceProcessingEnabled(_:)`
  (used by future phases) is only attachable to the live graph because the API
  refuses `.offline`; the offline graph runs the equivalent DSP through a
  vDSP-implemented `AVAudioUnit` instead — Phase 36's concern, but the master-bus
  design explicitly accommodates it.
- **R1.3** Engine lifecycle calls (`prepareLive`, `teardownLive`,
  `prepareOffline`, `renderOfflineBlock`, `teardownOffline`) are idempotent: a
  failed start does not leak nodes and a repeated stop is a no-op.
- **R1.4** Per-project audio track inputs (`TrackInput`) carry pan + linear
  gain; `MasterBus` carries master linear gain.

## R2 — Per-clip volume envelopes

- **R2.1** `VolumeEnvelope` extends — does not replace — the existing
  `AVMutableAudioMixInputParameters` transition ramps in
  `CompositionBuilder.swift`. A clip with the default empty envelope produces
  bit-identical preview / export to today's behaviour, **including transition
  crossfades**.
- **R2.2** `VolumeEnvelope.fadeIn` and `fadeOut` are clamped to the clip's
  effective duration at *render time*. When `fadeIn + fadeOut > clipDuration`,
  each fade is reduced to `clipDuration / 2`.
- **R2.3** Master gain and per-track gain are applied as a baseline-multiplier
  on existing transition ramps so transitions still crossfade correctly when
  the bus mutes / boosts a track.

## R3 — Metering

- **R3.1** The bus exposes an `@Observable` `AudioMeterSnapshot` updated from
  the master mixer's tap on the **audio thread**, surfaced through an
  `OSAllocatedUnfairLock` so the main actor can read it without races.
- **R3.2** The snapshot carries peak + RMS amplitude per channel (linear 0…1)
  and a `ContinuousClock.Instant` timestamp.
- **R3.3** The offline graph emits meter snapshots from its own tap during
  manual rendering, so the inspector's meter animates during export.
- **R3.4** Meter snapshot is **transient**: it is not part of `ProjectState`
  or `ProjectDocument`.

## R4 — Undo / persistence

- **R4.1** All bus mutations route through the existing
  `performUndoable` / `performCoalescedUndoable` patterns. Continuous gestures
  (slider drag) coalesce into a single undo step keyed on a target identifier.
- **R4.2** `ProjectState` grows fields for the bus parameters and per-clip
  envelopes so swap-based undo restores them atomically with the rest of the
  project.
- **R4.3** `ProjectDocument` round-trips master gain, every `TrackInput`, and
  every clip's `VolumeEnvelope` losslessly. Legacy documents without these
  fields decode to defaults (master gain 1, no track input overrides, empty
  envelopes) and behave exactly as today.

## R5 — Inspector

- **R5.1** A new audio inspector section shows the master gain slider and a
  two-channel peak + RMS meter driven by the bus's `AudioMeterSnapshot`.
- **R5.2** Per-track pan / gain controls surface in the existing inspector's
  track grouping. Per-clip fade-in / fade-out controls surface in the clip
  section when an audio clip is selected.
- **R5.3** Slider control labels include the parameter's current numeric
  value (dB for gain, ±1 for pan) for accessibility (matches the
  `Opacity NN%` pattern in `InspectorView.swift`).

## R6 — Verification

- **R6.1** Unit test: setting `masterGain` is undoable; `undo()` restores the
  previous value.
- **R6.2** Unit test: after `renderOfflineBlock(into:)` is called, the
  bus's `meterSnapshot` reflects the rendered block's amplitude — i.e. a
  silent block leaves peak / RMS at 0, a synthesised non-silent block
  produces a positive snapshot.
- **R6.3** Unit test: the offline graph builds and accepts manual rendering
  **without** `setVoiceProcessingEnabled(_:)` having been called — proving
  the design respects the Apple constraint.
- **R6.4** Unit test: `VolumeEnvelope` `fadeIn` + `fadeOut` greater than the
  clip duration each clamp to `clipDuration / 2`; an envelope `Ramp` whose
  `range` extends past the clip duration clamps to the clip end.
- **R6.5** Unit test: a project with a default-empty `VolumeEnvelope` and
  default bus parameters produces the **same** `AVMutableAudioMix`
  `inputParameters` count and ramp set as before the bus existed (regression
  guard for the existing Phase 30 transition crossfade tests).
- **R6.6** `xcodebuild` (Debug, macOS) green; no test count regression.
