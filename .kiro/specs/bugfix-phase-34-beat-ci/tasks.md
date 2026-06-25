# Tasks: Phase 34 Beat Tools — CI test target crash & tempo octave error

> Status: **Complete**.

## Implementation

- [x] **B1.1** `onsetEnvelope` calls `vDSP_fft_zrip` (real in-place FFT) instead
  of `vDSP_fft_zip`, matching the `halfN` packed split-complex buffer.
  *(Landed on the PR #40 branch.)*
- [x] **B2.1** `dpBeatTrack` anchors its grid on `firstPeakTime` instead of the
  backward-projected `basePhase`; remove the now-dead `basePhase`.
  *(Landed on the PR #40 branch.)*
- [x] **B3.1** Add `octaveEnergyFraction` and a sub-harmonic correction loop to
  `estimateTempoBPM`, comparing raw onset energy at `bestLag/2` and `bestLag/3`.
- [x] **B3.2** Inline comments record why the raw-energy comparison and the 0.5
  threshold are used, and why the `/(count-lag)` normalisation is preserved.
- [x] **B3.3** Octave candidate lags use an ordered `[lower, upper]` list with a
  strict-`>` tie rule (prefer the lower lag) instead of a `Set`, so selection is
  deterministic — required by the SHA-keyed cache contract.
- [x] **B4.1** Bump `BeatAnalysisCache.version` 1 → 2 so v1 blobs holding the old
  half-tempo result are rejected and re-analysed after upgrade.

## Verification

- [x] **V1** `Test (macOS 26 / Xcode)` green on the PR head (the authoritative
  gate; the local run did not reproduce the parallel-worker crash).
- [x] **V2** `BeatDetectionCoreTests.deterministicFileAnalysis()` passes
  (tempo within 5 BPM of 120).
- [x] **V3** `BeatDetectionCoreTests.dpBeatTrackSnapsToPeaks()` passes
  (beats[0…3] land on the four onset peaks).
- [x] **V4** `BeatDetectionCoreTests.tempoEstimate()` still reports exactly
  120 BPM — no regression from the octave correction.
- [x] **V5** Numeric model confirms a genuine 60 BPM envelope is not doubled.
- [x] **V6** No test count regression from `main`.

## Notes

- B1/B2 were raised in PR #40 review (Codex P1/P2) and merged unfixed; B3 was not
  caught by any reviewer. See `bugfix.md` → *Process note*.
- The numeric validation model of `estimateTempoBPM`/`onsetEnvelope` lived in the
  investigation scratchpad, not the repo — the Swift unit tests are the
  committed regression.
