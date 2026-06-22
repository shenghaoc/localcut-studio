# Design: Capability Tiers (P8 / P26 native equivalent)

> Status: **Proposed**. Infrastructure prerequisite for Phase 37 (frame interpolation),
> Phase 41 (capture engine), and Phase 45 (program mode).

## Goal

A single, snapshotted view of "what this Mac can do" — chip family, unified-memory
size, hardware encoder count — so every accelerated feature reaches the same answer
from the same probe. The browser-editor's P8/P26 tiers map a WebGPU adapter +
`navigator.deviceMemory` + encoder counts to "baseline / accelerated / pro"; the
native equivalent reads the same shape of information out of `sysctl` +
`VTSessionCopyProperty` and freezes it into a `Sendable` struct at editor launch.

Per-feature gating is a tiny resolver layered on top: `Capabilities.tier(for:)`
returns the tier *for that feature* plus a reason string that the Diagnostics panel
(open infra, future spec) can surface, so a creator can tell why a feature is
degraded ("running in baseline because: only 8 GiB unified memory; needs ≥ 16
GiB for accelerated frame interpolation").

## Pieces

### `CapabilityTier`

```swift
enum CapabilityTier: Int, Comparable, Sendable, Codable {
    case baseline = 0    // works, possibly software-rendered or export-only
    case accelerated     // hardware-accelerated; preview-realtime where applicable
    case pro             // accelerated + extra encoder / memory headroom for multi-stream
}
```

`Comparable` so a feature's required tier is a `>=` check, not a switch.

### `Capabilities` snapshot

```swift
struct Capabilities: Sendable, Hashable {
    enum ChipFamily: Sendable, Hashable {
        case intel
        case appleSilicon(generation: Int)   // 1 = M1, 2 = M2, 3 = M3, etc.; 0 = unknown AS

        var isAppleSilicon: Bool { if case .appleSilicon = self { return true } else { return false } }
        var generation: Int? { if case .appleSilicon(let g) = self { return g } else { return nil } }
    }

    let chip: ChipFamily
    let unifiedMemoryBytes: UInt64
    let videoEncoderCount: Int          // VideoToolbox-reported hardware H.264/HEVC encoders
    let osVersion: OperatingSystemVersion

    var unifiedMemoryGiB: Double { Double(unifiedMemoryBytes) / (1024 * 1024 * 1024) }

    /// Resolved once at editor launch; this `let`-bound snapshot crosses actor
    /// boundaries by value, so a detached export task and the main-actor
    /// inspector see exactly the same numbers.
    static let current = Capabilities.probe()
}
```

#### Probing inputs

- **Chip family.** `sysctlbyname("hw.optional.arm64")` (returns `1` on Apple
  Silicon) distinguishes Intel from Apple Silicon. To pick a generation we read
  `hw.optional.arm64` + a board-string read (`hw.model` / `machdep.cpu.brand_string`)
  and map known prefixes (`Mac14`, `Mac15`, …) to generations. Unknown Apple
  Silicon falls through to `appleSilicon(generation: 0)` and the resolver treats
  it as baseline rather than guessing high.
- **Unified memory.** `sysctlbyname("hw.memsize")` returns the byte count;
  on Apple Silicon all of it is unified GPU-addressable.
- **Encoder count.** `VTCopyVideoEncoderList(nil, ...)` followed by a
  per-entry check of `kVTVideoEncoderList_IsHardwareAccelerated`
  (`VTVideoEncoderList.h` doesn't expose a "hardware only" options-dict
  key — the hardware flag is a per-encoder property). This is a **rough
  proxy** for concurrent hardware capacity: the list returns one row per
  (codec, encoder) implementation, not per concurrent encoder instance.
  A Mac with one H.264 + HEVC engine reports two hardware rows even
  though the silicon is one block. For the v1 multi-stream gate
  (Phase 41 / 45) this proxy is acceptable: Intel Macs return 0,
  baseline Apple Silicon returns 2–3, and Pro/Max/Ultra return more —
  enough signal to distinguish a single-stream host from a multi-stream
  one. A future revision can read `kVTVideoEncoderList_InstanceLimit`
  per encoder for finer-grained capacity gating; the API stays unchanged
  because the gate consumers (`.simultaneousCaptureStreams(count:)`)
  speak in stream count, not encoder rows.
- **OS version.** `ProcessInfo.processInfo.operatingSystemVersion` — needed by
  `Capabilities.tier(for:)` so APIs that ship in a specific macOS revision
  (`VTFrameProcessor` on macOS 15.4+, etc.) cannot be reached by a higher chip
  tier alone.

The snapshot is taken once at editor launch (eager `let current = …` evaluation)
and never re-probed. Hot-plugging an eGPU isn't supported on Apple Silicon;
on Intel we don't track display changes — both are out of scope.

### Decision API

```swift
enum CapabilityFeature: Sendable, Hashable {
    case frameInterpolation
    case simultaneousCaptureStreams(count: Int)
    case metalEffectChain
}

struct CapabilityVerdict: Sendable, Hashable {
    let tier: CapabilityTier
    /// Human-readable explanation of WHY this tier was chosen, surfaced in the
    /// Diagnostics panel. Always non-empty.
    let reason: String
}

extension Capabilities {
    func tier(for feature: CapabilityFeature) -> CapabilityVerdict
}
```

The resolver inspects the snapshot for the feature's needs and returns the
*minimum* of every gate. Each gate that *demotes* the verdict contributes a
clause to the reason; if the verdict ends at `pro` the reason names every gate
that cleared (e.g. "Apple Silicon M3; 32 GiB unified memory; 2 hardware
encoders").

Example: `frameInterpolation` resolver

1. Intel? → `.baseline`, reason `"VTFrameProcessor not available — Intel Mac"`.
2. macOS < 15.4? → `.baseline`, reason `"VTFrameProcessor requires macOS 15.4+"`.
3. Unknown Apple Silicon generation? → `.baseline`, reason `"Unknown Apple
   Silicon generation — treating as baseline"` (errs low).
4. M1 / M2 (any memory)? → `.accelerated` (export-only is the surface, see
   Phase 37 R5.1), reason `"VTFrameProcessor available — Apple Silicon M1"`
   or similar. Phase 37 reserves `.pro` for **M3 Pro/Max/Ultra and newer**,
   so M1 / M2 hosts — even with abundant memory — stay one tier down.
5. M3+ with < 24 GiB unified memory? → `.accelerated`, reason
   `"VTFrameProcessor available — Apple Silicon M3; only 16 GiB unified
   memory (pro tier needs ≥ 24 GiB to approximate Pro/Max/Ultra)"`.
6. M3+ with ≥ 24 GiB unified memory? → `.pro`, reason `"VTFrameProcessor
   available — Apple Silicon M3 Pro/Max/Ultra-class (≥ 24 GiB unified
   memory)"`. The 24 GiB threshold approximates the Pro/Max/Ultra binned-die
   split, since sysctl doesn't expose it directly: M3 base ships at 8 / 16 /
   24 GiB, Pro starts at 18 GiB, Max starts at 36 GiB. A base M3 with 24 GiB
   would falsely promote — accept this as the closest sysctl-only proxy.

The exact thresholds belong in the resolver source, not the spec — the spec
specifies that there ARE per-feature gates, the code names them.

`simultaneousCaptureStreams(count:)` is the only feature that takes a
parameter; the count is the requested simultaneous capture count (used by
Phase 41 / 45), checked against `videoEncoderCount`. The v1 surface
deliberately does NOT take resolution / fps — those concerns belong to
Phase 41's own per-source preflight (`SCStreamConfiguration` /
`AVCaptureSession` settings probe). The tier resolver answers "can this Mac
run N simultaneous streams at all?"; the per-source budget probe answers
"can it sustain this resolution and fps for that source?". The two compose:
a host that fails the per-source preflight at 4K60 may still pass at 1080p30,
so folding resolution into the tier verdict would collapse useful nuance.

## Forward references

- The Diagnostics panel ("feature-diagnostics chip", listed in `ROADMAP.md`
  open-infra row P25) is the natural surface for these reason strings. This
  spec ships the verdict; the panel is a future spec.
- Phase 37, 41, and 45 each consume `Capabilities.tier(for:)` directly — the
  resolver replaces the ad-hoc availability checks each phase would otherwise
  reinvent.

## Why this isn't the place for SFSpeechRecognizer

`SFSpeechRecognizer(locale:).supportsOnDeviceRecognition` is a **per-locale**
gate, not a chip-tier gate — `en-US` may report `true` while `tr-TR` reports
`false` on the same hardware. The capability tier is one snapshot per host;
mixing in a locale-keyed probe would muddle the contract. Phase 29
(`phase-29-auto-captions`) re-runs the speech gate per session and per locale
change in its own design — this spec does not.

## Why this isn't the place for VTFrameProcessor OS gating alone

Phase 37 needs **both** chip-tier and OS gating. The OS check
(`if #available(macOS 15.4, *)`) is cheap and lives at the call site; the
chip-tier check (M2 / M3 / memory) lives here. The resolver folds both into a
single `CapabilityVerdict` for the inspector and the Diagnostics panel — the
phase doesn't have to combine them itself.

## Performance considerations

- Probing happens once at launch; the snapshot is a value type and `Sendable`.
- The resolver is pure — no syscalls, no `VTSessionCopyProperty` after launch.
- `CapabilityTier`'s `Comparable` conformance means feature gates are O(1).

## Trade-offs

- **Snapshot vs. live re-probe.** A snapshot is simpler and safer under Swift 6
  concurrency: any actor can read it without `await`. The cost is that we don't
  notice a thermal throttle or an external display change at runtime — but
  neither would change the chip family or memory; that's a Phase 25 diagnostics
  concern, not a tier concern.
- **One enum of features vs. per-feature methods.** A single `CapabilityFeature`
  enum keeps the resolver in one place and lets the Diagnostics panel iterate
  features generically. Per-feature methods would scatter the gating logic
  across the codebase.
- **Hard `.baseline` on unknown chips.** Erring low is safer than erring high:
  a "thinks it's Pro" misread risks dropped frames during a live capture; a
  "thinks it's baseline" misread costs a creator a few rendered frames per
  second.
- **Reason strings owned by the resolver.** The phases consume the verdict but
  do NOT mint their own reason strings — that way the Diagnostics panel can
  surface them uniformly.

## Risks

- `VTCopyVideoEncoderList` semantics change across OS versions; we trap a
  failure and surface zero hardware encoders rather than crashing.
- `hw.model` mapping is a hard-coded prefix table; a brand-new chip lands as
  `appleSilicon(generation: 0)` until we update the table — the resolver
  treats unknown AS chips as baseline, so the failure mode is "feature
  unavailable until a point release", not "false positive".
- A test host without VideoToolbox (CI sandbox, unlikely) reports zero
  encoders; tests assert only that the verdict is *sensible*, not that it
  matches a specific tier.

## Non-goals

- Runtime re-probing during a session (no thermal / hot-plug handling).
- Per-codec gating (HEVC vs. AV1 is a separate concern — the encoder count
  drives the multi-stream gate, not the codec choice).
- Locale-keyed gates like `SFSpeechRecognizer.supportsOnDeviceRecognition`
  (Phase 29 handles that itself).
- Persisting the tier into `ProjectDocument` (a project moves between hosts;
  the tier follows the host, not the project).
- A UI panel that *shows* the verdict — feature-diagnostics owns the surface.
