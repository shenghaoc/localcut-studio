# Tasks: Build Warnings & Swift 6 Modernization

> Status: **Complete**.

## Deprecations

- [x] **D1** Ported `skinMask` + `skinBlend` off the deprecated CIKL `CIColorKernel(source:)`
  to **`[[ stitchable ]]` Metal Shading Language**, compiled once at runtime via
  `CIKernel.kernels(withMetalString:)`; load failure logs via `os_log` and degrades to a
  no-op. (A precompiled `.ci.metal` → `metallib` was tried first but the synchronized
  file-system group never threaded the `-cikernel` link flag, so the kernels weren't in
  `default.metallib` and `applySkinSmooth` silently no-op'd — caught by the render-path test.)
- [x] **D1-test** `skinSmoothRenderPathAltersPixels()` renders a skin-tone fixture through the
  compiled kernels and asserts pixels change — fails loudly if a kernel can't load (Codex
  review). `applySkinSmooth` exposed `internal` for the test.

## Swift 6 concurrency warnings

- [x] **C1** `ScopeSampler` — `nonisolated(unsafe) static let shared` → `nonisolated`.
- [x] **C2** `AudioInspectorView.fadeRow` — `set` parameter now `@escaping @MainActor
  (Double) -> Void`. `@MainActor` (not `@Sendable`) is correct: global-actor-isolated
  closures are implicitly `Sendable` *and* keep the isolation needed to touch `model`. Landed
  with R1.
- [x] **C3** `RenderQueue.pump` — `input`/`output` confined via `nonisolated(unsafe)` locals
  with a comment documenting the serial-`pumpQueue` ownership invariant.

## Dead-code warning

- [x] **W1** `Models.Keyframes.updateKeyframe` — `guard let i = firstIndex(…)` →
  `guard keyframes.contains(where:)`.

## Consolidation

- [x] **R1** New `LabeledSliderRow` view (generic over `BinaryFloatingPoint`, two caption
  styles). Adopted in colour grade (×5), beauty (×3), transition duration, track gain, and
  clip fades; removed `colourSlider`/`beautySlider`/the bespoke `fadeRow` layout. Labels,
  value formats, and accessibility pairing preserved. Master-gain row left as-is (its caption
  is intentionally voiced, unlike the others).
- [x] **R2** `EffectCompositor` colour grade — new `CIImage.applying(when:_:)` helper
  collapses the three repeated `CIFilter` plumbing blocks into a chain.
- [~] **R3** *(Deferred.)* Security-scoped `start` / `defer`-`stop` is a 2-line idiom around
  multi-`return` bodies; a closure wrapper would force-wrap those bodies and hurt clarity.
  Left as idiomatic inline.
- [~] **R4** *(Deferred.)* Composition track-insertion loops differ (video pooling) and are
  P0-sensitive; not worth the regression risk in a cleanup pass.

## Test modernization

- [x] **T1** `try #require` for clip/placement-lookup force-unwraps in `TransitionsTests`
  (6 tests) and `TrimAndDragTests` (3 tests). Setup-invariant unwraps (`videoTracks.first!`)
  left as-is.
- [x] **T3** Parameterized `CaptionTailFillerTests` with `@Test(arguments:)` (two families →
  two parameterized tests; cases now show individually in the navigator).
- [~] **T2** *(Not done.)* `guard case … Issue.record(…)` is already the idiomatic Swift
  Testing form for enum-case assertions; converting to `#require` needs awkward closures and
  reads worse. Left as-is.
- [x] **T-extra** Cleared the remaining test-target warnings in `CaptionsAndKeyframesTests`
  (Swift 6.3 `#expect`/`#require` macro false-positives): `presetSnapshotShape` uses
  `guard let` + `Issue.record` instead of `#require`, and the decode test computes every
  `??`/`.contains` into a plain `Bool` local before `#expect` so the macro can't decompose
  those operators.

## Verification

- [x] **V1** Build (Debug/macOS, app + tests via `buildForTesting`) — **zero warnings**, zero
  errors.
- [x] **V2** Suite green: **320 / 320** (up from 311; parameterized cases register
  individually + the render-path test — no count regression).
- [x] **V3** Skin-smoothing render path verified end-to-end by `skinSmoothRenderPathAltersPixels`
  (compiled kernels load and alter pixels).
- [ ] **V4** Manual VoiceOver pass on audio/colour/beauty sliders after R1 (recommended
  before release; not blocking the diff).

## Notes / out of scope

- The `ProjectBundleTests.fingerprintIndexCodableRoundTrip` flake (non-deterministic Codable
  key ordering) was fixed independently on `main` (#30) and is included here via rebase.
