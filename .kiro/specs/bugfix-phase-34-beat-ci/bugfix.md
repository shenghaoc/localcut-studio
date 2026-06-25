# Bugfix: Phase 34 Beat Tools — CI test target crash & tempo octave error

> Status: **Complete**. Closes the `Test (macOS 26 / Xcode)` failure on
> [`phase-34-beat-tools`](../phase-34-beat-tools/tasks.md) (PR #40).

The Phase 34 beat-tools foundation shipped three defects that the hosted
`Test (macOS 26 / Xcode)` job caught but the local validation run did not. The
first one crashed the whole app test target; the other two were latent until the
crash was cleared. Two of the three were flagged in PR #40 review but landed
unfixed; the third (tempo octave) was missed by every reviewer.

## Bugs

### B1 — vDSP real-FFT buffer overrun crashes the entire test target

`BeatDetectionCore.onsetEnvelope` packs `frameSize` (1024) real samples into
`halfN` (512) split-complex elements with `vDSP_ctoz` and allocates `realp` /
`imagp` with capacity `halfN`. It then called **`vDSP_fft_zip`** — the *full
complex* FFT — with `log2n = log2(1024) = 10`, which operates on 2¹⁰ = 1024
complex elements and reads/writes `realp[0…1023]` / `imagp[0…1023]`, overrunning
the 512-element allocations. The heap corruption hard-crashed the xctest worker.

Because Xcode runs the suite across parallel worker clones, the crash marked
**every test still queued on the crashed worker as failed in 0.000 s** — ~280
unrelated tests (transitions, captions, persistence…) appeared to fail at once,
masking the single real cause. The `onsetEnvelope` doc comment already described
the intended routine as `vDSP_fft_zrip`; only the call site was wrong.

- **Flagged in review**: PR #40 Codex **P1 — "Use vDSP's real FFT for the STFT"**
  ([discussion_r3471220540](https://github.com/shenghaoc/localcut-studio/pull/40#discussion_r3471220540)).
  Marked outdated but never resolved; the foundation merged with it open.
- **Fix**: call `vDSP_fft_zrip` (the real in-place transform that operates on the
  `halfN` packed elements matching the FFT setup created for `log2n`). Landed on
  the PR #40 branch.

### B2 — DP beat tracker emits a spurious leading beat before the first onset

`BeatDetectionCore.dpBeatTrack` seeded its grid loop at
`firstPeakTime.truncatingRemainder(dividingBy: interval)` — the bare phase
offset. When the first onset peak already lands on an integer multiple of the
beat interval (e.g. a peak at 0.5 s on a 0.5 s / 120 BPM grid) that phase is
`0.0`, so the tracker emitted a beat at `t = 0` where there is no onset, shifting
every subsequent beat index by one. `dpBeatTrackSnapsToPeaks` expects
`beats[0…3]` to land on the four peaks (0.5/1.0/1.5/2.0 s); it got
`[0.0, 0.5, 1.0, 1.5]`.

- **Flagged in review**: PR #40 Codex **P2 — "Start the tracked grid at the first
  onset"**
  ([discussion_r3471220542](https://github.com/shenghaoc/localcut-studio/pull/40#discussion_r3471220542)).
  Also outdated-but-unresolved at merge time.
- **Fix**: anchor the grid on `firstPeakTime` (itself a valid grid position)
  instead of the backward-projected phase, so beats begin at the first detected
  onset. Landed on the PR #40 branch.

### B3 — Tempo estimate locks onto the sub-harmonic (half tempo)

With B1 fixed, the suite ran and surfaced a single genuine assertion failure:
`BeatDetectionCoreTests.deterministicFileAnalysis()` asserts
`abs(tempoBPM - 120) < 5` on a synthetic 120 BPM WAV click track, but
`estimateTempoBPM` returned **≈ 60 BPM**.

`estimateTempoBPM` picks the integer lag with the highest autocorrelation. The
fixture's beat period is 21.53 frames — *not* an integer number of analysis
hops. The integer lag that best aligns with an integer *multiple* of that period
is lag 43 (≈ 2 beats, alignment error 0.06 frame) rather than lag 21 or 22
(error ≈ 0.5 frame), so the bare peak reports the half-tempo sub-harmonic. The
existing `tempoEstimate()` unit test only passes because its synthetic period is
an *exact* 10 frames, where every harmonic ties and the shortest lag wins.

The `score / (count - lag)` normalisation does not cause this (plain
autocorrelation picks lag 43 too) but it is specifically what makes the
integer-period unit test land on the fundamental, so it must be preserved.

- **Flagged in review**: **No.** Gemini, Codex, and Claude all reviewed PR #40;
  none mentioned tempo-octave accuracy. This bug was found only by running the
  cleared suite in CI.
- **Fix**: add a tempo-octave (sub-harmonic) correction. After the bare peak is
  chosen, if a lag near `bestLag/2` or `bestLag/3` retains at least
  `octaveEnergyFraction` (0.5) of the peak's raw onset energy, step down to that
  faster fundamental. Verified to yield 117.45 BPM on the fixture (within
  tolerance), keep `tempoEstimate()` at exactly 120, and leave a real 60 BPM
  track at 60.

## Why it matters

The whole point of the beat-tools foundation is "deterministic onset/tempo/beat
extraction." B1 made any analysis a crash; B2 placed snap/cut targets where no
onset exists; B3 reported tempo an octave off, which feeds the DP tracker's beat
interval and every BPM-derived UI value. All three sit on the critical path of
the feature's first real use.

## Process note

B1 and B2 were both raised in PR #40's automated review with concrete fixes and
shipped anyway because the local `xcodebuild test` run did not crash the same way
the hosted parallel run did. The lesson mirrors
[`bugfix-build-warnings-and-modernization`](../bugfix-build-warnings-and-modernization/bugfix.md):
**the hosted `Test (macOS 26 / Xcode)` job is the authoritative gate**, and
unresolved P1/P2 review threads should block merge rather than ride along as
"foundation" debt.
