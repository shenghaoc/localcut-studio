# Design: Audio Master Bus (P16 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 35 (speed ramps),
> Phase 36 (voice cleanup), and Phase 46 (replay buffer).

## Goal

Give the project a single, addressable **audio master bus** built on
`AVAudioEngine` that every audio path (per-track playback, future live capture,
future cleanup inserts) routes through. The bus carries a master gain stage,
per-input pan + gain, a per-clip volume envelope ramp pipeline that **extends**
(rather than replaces) the existing `AVMutableAudioMixInputParameters` ramps
already used by transitions in `CompositionBuilder.swift`, and a peak + RMS
metering tap surfaced through an `@Observable` snapshot for the inspector.

This spec is the **plumbing only**. Inserts (denoiser, gate, compressor,
limiter — Phase 36), capture-side routing (Phase 41/46), and time-stretch
pitch preservation (Phase 35) attach to this bus in their own specs.

## Scope split: live vs. offline graph

`AVAudioEngine` has two rendering modes:

- **`.realTime`** — drives the output device, used during preview / monitor.
- **`.offline`** (set via `enableManualRenderingMode(_:format:maximumFrameCount:)`)
  — pulls audio on demand into a caller-supplied buffer; used for export.

These two modes are not interchangeable. Per [ROADMAP `Apple API
spot-checks`](../ROADMAP.md#apple-api-spot-checks),
`AVAudioInputNode.setVoiceProcessingEnabled(_:)` (used by Phase 36 / Phase 41
on the input side) **refuses `manualRenderingMode = .offline`** — WWDC19 §510.
The design must accommodate that constraint up-front: the bus owns **two
parallel `AVAudioEngine` graphs**, built from one shared graph description.
Phase 36 attaches voice-processing only to the live graph; the offline graph
runs the same DSP via the bypass-able vDSP `AVAudioUnit` path Phase 36
specifies for parity with preview.

```text
                AudioMasterBus
        ┌───────────────────────────┐
        │  graph description (one)  │
        │  inputs, gain, pan, …     │
        └────────────┬──────────────┘
                     │
        ┌────────────┴──────────────┐
        ▼                           ▼
┌────────────────┐         ┌──────────────────┐
│ liveEngine     │         │ offlineEngine    │
│ .realTime      │         │ .offline         │
│ → output device│         │ → manualRender   │
│   (preview)    │         │   into caller buf│
└────────────────┘         └──────────────────┘
       ▲                              ▲
       │ AVPlayer routing (when bus   │ AVAssetWriter / AVAssetReader
       │ is engaged for monitoring;   │ render block during export
       │ AVPlayer keeps its own audio │
       │ until then — see below)      │
```

`AVPlayer` does its own AU graph internally. Phase 36 routes the export path
through the offline graph by reading the composition with `AVAssetReader`,
feeding samples into the offline `AVAudioEngine`'s `AVAudioPlayerNode`
inputs, pulling rendered blocks, and writing them through `AVAssetWriter`.
Preview wiring is staged: the editor starts the live bus on window appearance
so the inspector meter is connected, but until Phase 36 lands the inserts and
audio routing the live graph renders silence while `AVPlayer` preview remains
unchanged. Phase 36 flips the preview path to the bus by replacing the
`AVPlayer` audio with an `AVAudioEngine`-backed `AVAudioPlayerNode` chain at
the bus's inputs. This staging is explicit so landing the bus does not regress
current playback.

## Engine types

```swift
@MainActor
@Observable
final class AudioMasterBus {
    /// Single source of truth for the bus's user-facing parameters.
    /// `MainActor` because edits are driven by inspector / undo on the main
    /// thread; sample-rate-isolated DSP state lives in the audio nodes.
    /// Snapshot updated on the audio thread, read by SwiftUI for the meter.
    /// The snapshot value type is `Sendable`; the audio thread writes through
    /// an `OSAllocatedUnfairLock` and the main thread reads under the same
    /// lock via a computed accessor.
    var meterSnapshot: AudioMeterSnapshot { get }

    init()

    // Live + offline graph lifecycle.
    func prepareLive()                   // starts the live engine, swallows errors via lastStartError
    func teardownLive()                  // stops the live engine, removes taps
    func prepareOffline(format: AVAudioFormat,
                        maximumFrameCount: AVAudioFrameCount) throws
    func renderOfflineBlock(into buffer: AVAudioPCMBuffer) throws
                                         -> AVAudioEngineManualRenderingStatus
    func teardownOffline()
}
```

Bus parameters live on `Project` (master gain + per-track inputs) and per-clip
envelopes ride on `Clip.volumeEnvelope`; the `AudioMasterBus` runtime engine
reads them through `AudioBusMixing` helpers when `CompositionBuilder` builds
audio mix parameters. Mutators on `EditorModel` (`setMasterGain`,
`setTrackInput`, `setClipVolumeEnvelope`) route through the existing
`performUndoable` / `performCoalescedUndoable` machinery so bus edits join the
same undo stack as every other project mutation.

```swift
struct TrackInput: Identifiable, Hashable {
    let id: Track.ID
    var pan: Float = 0          // −1 (L) … +1 (R)
    var gain: Float = 1         // linear, 0…2
}

struct AudioMeterSnapshot: Hashable, Sendable {
    /// Peak amplitude over the last sampled block, per channel (linear, 0…1).
    var peakLeft: Float
    var peakRight: Float
    /// RMS amplitude over the last sampled block, per channel (linear, 0…1).
    var rmsLeft: Float
    var rmsRight: Float
    /// Wall-clock at the sample, so the inspector's hold/decay can debounce.
    var sampledAt: ContinuousClock.Instant
}
```

`VolumeEnvelope` is the **extension** of the existing per-clip fade mechanism:

```swift
/// A per-clip envelope of linear-gain ramps. An empty envelope means "use
/// transition-derived ramps only" (today's behaviour, untouched).
struct VolumeEnvelope: Hashable, Codable {
    struct Ramp: Hashable, Codable {
        /// **Clip-relative** time range — `start = 0` is the clip's head.
        /// The build pipeline shifts this onto the clip's effective timeline
        /// position per piece, so the automation moves with the clip on
        /// drag / trim / split.
        var range: CMTimeRange
        var fromVolume: Float
        var toVolume: Float
    }
    var ramps: [Ramp] = []            // applied in addition to transition ramps
    var fadeIn: CMTime = .zero        // 0 ⇒ no fade-in
    var fadeOut: CMTime = .zero       // 0 ⇒ no fade-out
}
```

`fadeIn` / `fadeOut` are convenience knobs that lower into two implicit
`Ramp` entries (clip-relative `[0, fadeIn]` and `[clipDur − fadeOut, clipDur]`)
clamped to the clip's duration at render time; longer values than the clip
duration clamp to that duration (split evenly when both fade-in and fade-out
exceed half-length).

**Multi-piece clips.** A clip spanning another track's transition cut gets
split into multiple `TransitionLayout.Piece`s. Fades emit on the **first**
piece (fadeIn) and the **last** piece (fadeOut) only; envelope ramps emit on
each piece their clip-relative range intersects, with endpoints linearly
interpolated for the sub-range.

**Transition precedence at the cut.** Where a transition crossfade ramp
already occupies the head / tail of a piece, envelope writes inside that
window would overwrite the crossfade (last write wins in
`AVMutableAudioMixInputParameters`). Envelope writes are restricted to the
non-transition portion of each piece so transitions remain authoritative at
the cut.

## Integration with `CompositionBuilder`

`CompositionBuilder.swift` already builds `AVMutableAudioMixInputParameters`
for each placed audio piece and calls `setVolumeRamp(fromStartVolume:
toEndVolume: timeRange:)` for transition leads/tails. The bus extends that
path; it does not replace it.

Build-order change (new method `applyAudioBusParameters(_:on:from:)` invoked
right after the existing transition ramp loop, before the
`AVMutableAudioMix` is finalised):

1. Existing transition crossfade ramps are written first (unchanged).
2. For each `AVMutableAudioMixInputParameters`:
   - Multiply through `bus.masterGain × trackInput.gain` by inserting a
     `setVolume(_:at:)` baseline at the piece's effective start, **then
     re-applying the existing transition ramps** so they ramp around the
     new baseline. Ramps are linear in linear gain, so a new baseline `g`
     turns `setVolumeRamp(from: a, to: b, timeRange: R)` into
     `setVolumeRamp(from: a * g, to: b * g, timeRange: R)`.
   - For every `Ramp` in the clip's `VolumeEnvelope` whose `range`
     intersects the piece, emit a `setVolumeRamp(...)` over the intersected
     interval, baseline-multiplied.
3. Pan is **data-model-only** in this spec — `TrackInput.pan` is persisted
   and undoable, but the audio rendering path stays a per-input volume
   scalar. Applying pan requires a per-track `AVAudioMixerNode.pan` write on
   the live graph plus a panner node on the offline graph, both of which sit
   inside Phase 36's owned audio rendering pipeline. The inspector therefore
   does not surface a pan control until Phase 36; existing pan field values
   round-trip but do not affect audio.

This keeps the **existing transition ramp behaviour bit-identical** when the
envelope and bus gains are at defaults (`fadeIn = fadeOut = 0`, no ramps,
gains = 1.0, pan = 0). The Phase 30 audio crossfade tests stay green without
modification.

## Clip-fade clamping

`fadeIn` and `fadeOut` are clamped to the clip's effective duration on every
read by the builder. `fadeIn + fadeOut > clipDuration` ⇒ each fade gets
`clipDuration / 2`. This is a clamp at *render* time, not at *mutate* time,
because clip durations change behind the envelope (trim, ripple, time-stretch
in Phase 35) and re-clamping on every length tick would lose the user's
authored intent on a temporary shortening.

## Metering

`AVAudioMixerNode.installTap(onBus: 0, bufferSize:, format:, block:)` on the
live graph's master mixer publishes blocks of PCM samples on the audio thread.
The block computes peak (max abs sample) and RMS (sqrt of mean square)
per channel, packs an `AudioMeterSnapshot`, and writes it through the
`OSAllocatedUnfairLock` that protects `meterSnapshot`. The inspector reads via
the `@Observable` accessor; SwiftUI repaints when the underlying instance
changes. Tap buffer size = 1024 frames (≈21 ms at 48 kHz) — small enough that
the meter looks live, large enough that the tap doesn't dominate the audio
thread's budget.

In offline mode, a second tap on the offline graph's master mixer runs the
same compute and updates the same snapshot per rendered block, so the
inspector's meter animates during export too.

The meter snapshot is **not** part of `ProjectDocument` — it is transient
runtime state.

## Persistence

`ProjectDocument` grows three Codable blobs, all behind lenient decoders
matching the existing pattern:

```swift
struct AudioBusDoc: Codable, Hashable {
    var masterGain: Float = 1
    var trackInputs: [TrackInputDoc] = []
    // Forward-compat is handled by the outer `ProjectDocument.schemaVersion`
    // (matches `CaptionTrackDoc` — no inner version field needed).
}

struct TrackInputDoc: Codable, Hashable {
    var trackID: UUID
    var pan: Float = 0
    var gain: Float = 1
}

struct VolumeEnvelopeDoc: Codable, Hashable { ... }
```

`Clip` carries its `VolumeEnvelope` on disk; legacy clips decode to an empty
envelope and behave exactly as today. The `ProjectDocument.schemaVersion`
bumps in line with the existing convention.

## Undo / coalescing

Master-bus mutations route through the existing
`performUndoable(_:)` / `performCoalescedUndoable(_:target:rebuild:mutate:)`
machinery in `EditorModel+Persistence.swift`:

- `setMasterGain(_:)`, `setTrackGain(_:trackID:)`, `setTrackPan(_:trackID:)`
  on a drag use `performCoalescedUndoable("Adjust Master Gain", target: nil,
  rebuild: .debounced)`. A discrete reset uses `performUndoable`.
- `setClipVolumeEnvelope(_:clipID:)` keyed by clip id, same pattern as
  `updateSelectedClipCoalesced` so envelope drags fold into one undo step.
- `ProjectState` (in `EditorModel+Persistence.swift`) grows fields for the
  bus + per-clip envelope so swap-based undo restores them atomically with
  the rest of the project.

The bus's *live audio nodes* are not part of `ProjectState` — only the
parameter snapshot is. Restoration re-applies parameters by setting them
through the public mutators on the bus instance, which the model holds for
the session.

## Inspector

A new `AudioInspectorView` (driven by `EditorModel.audioBus`) renders inside
the existing inspector's `Form`, next to the `Captions` section. It shows:

- **Master gain** slider (−∞…+6 dB log-mapped from linear 0…2).
- **Master meter** — two-channel peak + RMS bars, hold = 1.5 s, decay = 12 dB/s,
  driven by the `AudioMeterSnapshot` published by the bus.
- (Phase 36 adds insert toggles below; this spec leaves the section
  expandable.)

Per-track pan / gain rows surface inside the existing `Captions`-style
disclosure-per-track grouping. Per-clip fade-in / fade-out rows surface
inside the existing clip inspector section when the selected clip is on
an audio track.

## Risks

- **`AVAudioEngine` start failure** (e.g. headless test environment with no
  audio device): the bus must surface the error through `statusMessage` and
  fall back to a no-op metering snapshot. Live engine teardown must be
  idempotent so a failed start doesn't leak nodes.
- **Audio-thread reentrancy** into observable state: meter snapshots are
  published through an `OSAllocatedUnfairLock` rather than a property
  observer to avoid SwiftUI re-entrancy on the audio thread.
- **Sample-rate / channel-count mismatches** between source clips: the bus's
  master mixer normalises to a single output format (48 kHz stereo float) so
  downstream Phase 36 DSP sees one canonical format.
- **Manual-rendering edge cases**: `enableManualRenderingMode` requires
  detaching/reattaching some node types; the offline graph builder must
  reattach everything from the shared description rather than sharing
  `AVAudioNode` instances with the live graph.

## Non-goals

- Inserts (denoiser, gate, compressor, limiter) — Phase 36.
- Live mic / system-audio capture routing — Phase 41 / 46.
- Pitch-preserving time stretch — Phase 35.
- Per-clip pan automation via keyframes — Phase 35 (uses the keyframe infra).
- Bus sends / aux returns — out of scope; a future spec if multi-bus is needed.
- Surround / Atmos channel layouts — stereo only for v1.
- Loudness measurement (LUFS / EBU R128) — Phase 36.
