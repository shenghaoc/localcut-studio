# Tasks: FingerprintIndex JSON Determinism

> Status: **Complete**.

## Implementation

- [x] **B1.1** Set `outputFormatting = [.prettyPrinted, .sortedKeys]` on the
  encoder in `FingerprintIndex.encoded()`.
- [x] **B1.2** Keep the manual `entries.keys.sorted()` loop in `encode(to:)`
  as a second guard against future container-shape changes that the encoder
  would not auto-sort.
- [x] **B1.3** Comment in `ProjectBundle.swift` explains why both guards are
  needed (neither alone covers every regression path).

## Verification

- [x] **V1** `xcodebuild` (Debug, macOS) green.
- [x] **V2** `ProjectBundleTests.fingerprintIndexCodableRoundTrip` passes 20
  consecutive runs (was flaky on the rewritten `JSONEncoder`; deterministic
  with `.sortedKeys`).
- [x] **V3** No test count regression from `main`.
