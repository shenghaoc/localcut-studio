# Tasks: Capability Tiers

> Status: **Implemented**.

## Model

- [x] **T1.1** Add `CapabilityTier` enum (`.baseline`, `.accelerated`, `.pro`)
      conforming to `Comparable`, `Sendable`, `Codable`.
- [x] **T1.2** Add `Capabilities` value type with `chip`, `unifiedMemoryBytes`,
      `videoEncoderCount`, `osVersion`; `Sendable`.
- [x] **T1.3** Add `Capabilities.ChipFamily` enum (`.intel`,
      `.appleSilicon(generation:)`) with `isAppleSilicon` and `generation`
      conveniences.
- [x] **T1.4** Land `Capabilities` and the resolver in a new
      `LocalCut Studio/Capabilities.swift`.

## Probe

- [x] **T2.1** `sysctlbyname` reads for `hw.optional.arm64`, `hw.memsize`,
      and `hw.model`; chip-generation mapping table.
- [x] **T2.2** Hardware encoder count via `VTCopyVideoEncoderList` with the
      hardware-acceleration filter key.
- [x] **T2.3** OS version via `ProcessInfo`. Snapshot is `static let current`
      on `Capabilities` — eager, evaluated once at first access.

## Decision API

- [x] **T3.1** `CapabilityFeature` enum: `.frameInterpolation`,
      `.simultaneousCaptureStreams(count:)`, `.metalEffectChain`.
- [x] **T3.2** `CapabilityVerdict { tier, reason }`.
- [x] **T3.3** `Capabilities.tier(for:)` resolver with per-feature gates and
      non-empty reason strings.
- [x] **T3.4** Frame interpolation gates on `osVersion >= 15.4` AS WELL AS
      chip tier; an older OS reports `.baseline` regardless of chip.

## Verification

- [x] **T4.1** Unit tests covering tier ordering, snapshot stability,
      non-empty reasons, the Intel and old-OS frame-interpolation paths, and
      the encoder-exceeded capture path. Synthetic `Capabilities` constructor
      used to exercise the resolver without depending on the test host.
- [x] **T4.2** `xcodebuild` (Debug, macOS) green; no test count regression.

## Roadmap

- [x] **T5.1** Move the `Capability tiers (P8/P26)` row out of `ROADMAP.md`'s
      "Open infra" table and into the "Existing spec" prerequisite table.
