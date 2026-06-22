# Requirements: Capability Tiers

> Status: **Proposed**.

## R1 — Tier model

- **R1.1** A `CapabilityTier` enum with cases `.baseline`, `.accelerated`,
  `.pro`. Conforms to `Comparable`, `Sendable`, and `Codable`. Ordering is
  `baseline < accelerated < pro` so a feature's required tier is a `>=` check.
- **R1.2** A `Capabilities` value type, `Sendable`, carrying the probed values
  (chip family, unified-memory bytes, hardware video encoder count, OS version).
- **R1.3** A `Capabilities.ChipFamily` enum distinguishes Intel from Apple
  Silicon and, for Apple Silicon, carries a generation integer (1 = M1,
  2 = M2, 3 = M3, etc.). Unknown Apple Silicon decodes to `generation: 0`.

## R2 — Probing

- **R2.1** Probing inspects `sysctlbyname("hw.optional.arm64")` to distinguish
  Intel from Apple Silicon. Apple Silicon generation is derived from a
  board-string read (`hw.model`).
- **R2.2** Unified-memory size is read from `sysctlbyname("hw.memsize")`.
- **R2.3** Hardware video encoder count is derived from
  `VTCopyVideoEncoderList` called with a `nil` options dict; entries are
  counted by checking the per-entry `kVTVideoEncoderList_IsHardwareAccelerated`
  property (the header exposes no "hardware only" options-dict key —
  hardware acceleration is a per-encoder attribute). A probe failure
  surfaces zero encoders rather than crashing.
- **R2.4** OS version is `ProcessInfo.processInfo.operatingSystemVersion`.
- **R2.5** The snapshot is captured ONCE at editor launch (a `static let
  current` on `Capabilities`) and never re-probed within a session.
- **R2.6** The snapshot returns the same values across repeated reads — the
  resolver is pure and side-effect-free after launch.

## R3 — Decision API

- **R3.1** A `CapabilityFeature` enum carries the features that consume the
  resolver: `.frameInterpolation`, `.simultaneousCaptureStreams(count: Int)`,
  `.metalEffectChain`.
- **R3.2** `Capabilities.tier(for: CapabilityFeature)` returns a
  `CapabilityVerdict { tier: CapabilityTier, reason: String }`.
- **R3.3** The `reason` string is non-empty for every verdict and names the
  binding constraint (e.g. `"VTFrameProcessor available — Apple Silicon M2+;
  ≥ 16 GiB unified memory"`).
- **R3.4** Frame interpolation's verdict gates on BOTH chip tier and
  `osVersion >= 15.4` — older OS reports `.baseline` regardless of chip.
- **R3.5** `simultaneousCaptureStreams(count:)` returns `.baseline` when the
  requested count exceeds the available hardware encoder count.
- **R3.6** The resolver NEVER returns a tier above the host's capability —
  baseline hardware cannot reach `.accelerated` for a feature that requires it.

## R4 — Concurrency

- **R4.1** `Capabilities` is `Sendable` and crosses actor boundaries by value.
- **R4.2** The decision API is `nonisolated` (or naturally pure) so any actor —
  the main-actor `EditorModel`, a detached export task, a capture session
  actor — can call it without `await`.

## R5 — Verification

- **R5.1** Unit tests under `LocalCut StudioTests/` cover:
  - `CapabilityTier` ordering (`.baseline < .accelerated < .pro`).
  - The snapshot is stable across calls (`Capabilities.current === Capabilities.current`
    in value-equality terms).
  - `tier(for:)` returns a sensible, non-empty `reason` for every feature on
    the test host.
  - Frame interpolation on an Intel-typed `Capabilities` value returns
    `.baseline` with a reason naming the chip.
  - `frameInterpolation` on an Apple Silicon-typed value with
    `osVersion.major < 15` returns `.baseline` with a reason naming the OS.
  - `simultaneousCaptureStreams(count: N)` for an `N` that exceeds the encoder
    count returns `.baseline`.
- **R5.2** A synthetic `Capabilities` constructor (or builder, in test-only
  scope) lets tests exercise tier transitions without depending on the host.
- **R5.3** `xcodebuild` (Debug, macOS) green; no test count regression.
