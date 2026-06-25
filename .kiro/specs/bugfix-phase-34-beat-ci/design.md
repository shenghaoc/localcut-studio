# Design: Phase 34 Beat Tools — CI test target crash & tempo octave error

Three narrow fixes inside `BeatDetectionCore` (`LocalCut Studio/BeatTools.swift`).
No public API change, no `.beat` cache format change, no schema bump. The cache
header (`magic`/`version`) and `BeatAnalysis` Codable shape are untouched, so
existing blobs still decode.

## B1 — `vDSP_fft_zip` → `vDSP_fft_zrip`

The STFT packs `frameSize` real samples into `halfN = frameSize/2` split-complex
elements via `vDSP_ctoz`, and `realp`/`imagp` are allocated with capacity
`halfN`. The real in-place transform operates on exactly those `halfN` elements:

```swift
// before — full complex FFT, reads/writes 2^log2n = frameSize elements
vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
// after — real in-place FFT, operates on the halfN packed elements
vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
```

`vDSP_create_fftsetup(log2n, …)` was already created for `log2n = log2(frameSize)`,
which is the correct setup size for `zrip`. The magnitude step
(`vDSP_zvmags` over `halfN`) is unchanged; `zrip` packs DC in `realp[0]` and
Nyquist in `imagp[0]`, which is an acceptable approximation for a spectral-flux
onset envelope and does not affect determinism.

## B2 — Anchor the DP grid on the first onset

```swift
// before
let basePhase = firstPeakTime.truncatingRemainder(dividingBy: interval)
var t = basePhase
// after
let firstPeakTime = Double(peaks.first!) * hopDuration
var t = firstPeakTime
```

`firstPeakTime` is itself a valid grid position (the phase is derived from it),
so stepping by `interval` from there keeps the same grid while dropping the
pre-roll beats projected backward into leading silence. `basePhase` becomes
dead and is removed.

## B3 — Tempo-octave correction in `estimateTempoBPM`

The bare estimator is unchanged: it still picks the lag maximising
`autocorrelation(lag) / (count - lag)`, which keeps `tempoEstimate()` (exact
10-frame period) on the fundamental. A correction loop runs **after** the peak
is chosen:

```swift
var improved = true
while improved {
    improved = false
    let peakEnergy = autocorrelation(at: bestLag)
    guard peakEnergy > 0 else { break }
    for divisor in [2, 3] {
        let target = Double(bestLag) / Double(divisor)
        guard target >= Double(minLag) else { continue }
        let candidates = Set([Int(target.rounded(.down)), Int(target.rounded(.up))])
        // pick the straddling integer lag with the most onset energy …
        if let pick, pick.energy >= peakEnergy * octaveEnergyFraction {
            bestLag = pick.lag
            improved = true
            break
        }
    }
}
```

Key choices:

- **Raw autocorrelation for the comparison**, not the `/(count-lag)` normalised
  score. The normalisation biases toward larger lags (smaller denominator);
  using raw energy asks the honest question "does the doubled rate actually
  carry onsets?".
- **Threshold `octaveEnergyFraction = 0.5`.** A true sub-harmonic of a faster
  pulse retains most of the peak energy at half/third lag; a genuine slow track
  has almost none at the doubled rate, so it is left alone. Verified: a real
  60 BPM envelope stays at 60.
- **Straddling candidates** (`floor`/`ceil` of `bestLag/divisor`) handle the
  non-integer sub-harmonic lag (43/2 = 21.5 → check 21 and 22).
- **Loop** so a 3rd/4th sub-harmonic steps down repeatedly; it terminates once
  no candidate stays within range and above threshold.

### Verified behaviour (numeric model of the shipped algorithm)

| Input | Before | After |
| --- | --- | --- |
| 120 BPM WAV fixture (period 21.53 frames) | 60.09 BPM ✗ | **117.45 BPM** ✓ (`< 5` of 120) |
| `tempoEstimate()` envelope (exact 10-frame period) | 120.0 BPM | **120.0 BPM** ✓ (unchanged) |
| Genuine 60 BPM envelope | 60.09 BPM | **60.09 BPM** ✓ (not doubled) |

The residual 117.45 vs 120 is integer-lag quantisation (lag 22 vs ideal 21.53);
sub-frame parabolic interpolation could tighten it but is unnecessary for the
±5 BPM contract and is left as a future refinement.

## Out of scope

The other PR #40 review items (cache invalidation, `canCutSelectedClipAtBeats`
permissiveness, security-scope lifetime, snap-target caching, per-clip beat
selection) are editor-model behaviour, not the CI crash. They are tracked on the
feature PR and intentionally excluded here so this bugfix stays surgical.
