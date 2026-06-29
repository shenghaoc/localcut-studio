# Tasks: CMTimeCode Timescale Guard

> Status: **Complete**.

## Implementation

- [x] **T1.1** Reject non-positive stored timescales before constructing
  `CMTime`, collapsing corrupt decoded values to `.zero`.
- [x] **T1.2** Preserve exact round-trip behaviour for valid `CMTimeCode`
  values.
- [x] **T1.3** Audit shared `CMTimeCode` consumers: clips, media refs,
  transitions, keyframes, and markers all convert through the guarded accessor.

## Verification

- [x] **V1** Add a Swift Testing regression for decoded `timescale: 0` collapsing
  to `.zero`.
- [x] **V2** Include a positive-value / negative-timescale case in the same
  regression.
- [x] **V3** Focused `PersistenceTests` pass.
- [x] **V4** Full macOS `xcodebuild test` suite passes.
