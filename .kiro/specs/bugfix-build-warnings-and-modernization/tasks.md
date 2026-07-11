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
- [x] **D2** `CompositionBuilder.crossDissolveLayerInstructions` migrated off the macOS-26-
  deprecated `AVMutableVideoCompositionLayerInstruction` to
  `AVVideoCompositionLayerInstruction.Configuration` (`init(trackID:)` + `setTransform` +
  `addOpacityRamp`), returning the immutable `AVVideoCompositionLayerInstruction`. Test reads
  ramps via the modern `opacityRamp(at:)`. CI-only deprecation (Xcode 26.5); no behaviour change.

## Swift 6 concurrency warnings

- [x] **C1** `ScopeSampler` — `nonisolated(unsafe) static let shared` → `nonisolated`.
- [x] **C2** `AudioInspectorView` fades — build the `Binding<Double>` inline in a
  `fadeBinding(_:)` helper (the `masterGainBinding` shape) so the setter's main-actor isolation
  is *inferred*, no annotated closure forwarded. (An interim `@escaping @MainActor (Double) ->
  Void` parameter fixed the warning locally but **crashed Swift 6.3.2 on CI** in IRGen emitting
  the `@MainActor`→`@Sendable` reabstraction thunk for `Binding.set` — see the CI-crash note.)
- [x] **C3** `RenderQueue.pump` — `input`/`output` confined via `nonisolated(unsafe)` locals
  with a comment documenting the serial-`pumpQueue` ownership invariant.
- [x] **C4** *(post-rebase Swift-6 sweep)* Dropped `@unchecked` from four lock-guarded caches —
  `RenderCache`, `ScopeSampler`, `TitleRasterer`, `CaptionRasterer` are now plain `Sendable`
  (their only stored state is an `OSAllocatedUnfairLock` / immutable `let`), so the compiler
  *verifies* thread-safety instead of trusting the escape hatch. The remaining
  `nonisolated(unsafe)` deinit-observer fields (`EditorModel`, `DiagnosticsAgent`,
  `TimelineView`) are **required** (nonisolated `deinit` touching main-actor state) — confirmed
  by the build not flagging them, left in place.

## Dead-code warning

- [x] **W1** `Models.Keyframes.updateKeyframe` — `guard let i = firstIndex(…)` →
  `guard keyframes.contains(where:)`.

## Consolidation

- [x] **R1** New `LabeledSliderRow` view (generic over `BinaryFloatingPoint`, two caption
  styles). Adopted in colour grade (×5), beauty (×3), transition duration, track gain,
  clip fades, and **clip opacity** (the last added in the post-rebase dedup sweep); replaced
  `colourSlider`/`beautySlider` and the bespoke opacity/fade slider layouts with shared row
  calls. Labels, value formats, and accessibility pairing preserved; `.inline` caption carries
  `.monospacedDigit()` (Claude review P2). Master-gain row left as-is (its caption is
  intentionally voiced) and the timeline-zoom slider is a bare icon-flanked control with no
  caption — neither fits the row.
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

## PR #93 follow-up Swift 6 sweep

- [x] **F1** Replaced the remaining targeted `NSLock` instances in overlay frame caches,
  capture sessions/writers, live/program compositors, publish taps, and test helpers with
  immutable `OSAllocatedUnfairLock` instances.
- [x] **F2** Kept non-`Sendable` Core Video/Core Media/WebRTC values behind
  `withLockUnchecked`; preserved compiler-checked `withLock` for plain value state.
- [x] **F3** Preserved framework and callback boundaries outside critical sections. Removed the
  unreachable `FinishAction.throw` branch left by the capture-writer completion refactor.
- [x] **F4** Added explicit `Sendable` conformance to the affected stateless namespace enums,
  compatible error enums, and value-only state structs in the app and LocalCutCore.
- [x] **F5** Replaced deprecated `URL(fileURLWithPath:)` construction in the two affected source
  helpers and the touched app/package test fixtures, preserving directory hints where needed.
- [x] **F6** Merged current `main` and resolved the four overlapping concurrency files by keeping
  `main`'s actor isolation, lifetime documentation, and non-WebRTC storage accessor alongside
  the PR's valid lock migrations. The later required-WebRTC platform extraction removed that
  historical fallback accessor.
- [x] **F7** Cleared the post-merge Swift 6 diagnostics in `CaptionTailFiller`, `ContentView`,
  and `ProgramCompositor` without changing asynchronous action, cancellation, or lock behaviour.
- [x] **F8** Final local gate: `git diff --check`, LocalCutCore package build/tests (175 tests),
  the full Debug/macOS suite (792 executed test-case lines, first-attempt pass, zero build
  warnings), the non-WebRTC publish suite (9 tests), MediaMTX WHIP integration (2 tests), and
  7 OTIO golden fixtures pass. These are the historical completion results; the current CI has
  no non-WebRTC product lane because macOS always builds `LocalCutPlatform` with WebRTC.
- [x] **F9** Fixed the CI failure-retry path to resolve Swift Testing suite/test names to their
  recorded Xcode test target before passing `-only-testing:`. Relaxed the App Intents cancellation
  assertion from a scheduler-sensitive 100 ms to a still-bounded one-second deadline against its
  60-second predecessor.

## Verification

- [x] **V1** Build (Debug/macOS, app + tests via `buildForTesting`) — **zero warnings**, zero
  errors on **both** the macOS 27 dev host and the macOS 26 / Xcode 26.5 CI toolchain
  (the D2 deprecation only appeared on CI; confirmed cleared in the CI build log).
- [x] **V2** Suite green: **320 / 320** (up from 311; parameterized cases register
  individually + the render-path test — no count regression).
- [x] **V3** Skin-smoothing render path verified end-to-end by `skinSmoothRenderPathAltersPixels`
  (compiled kernels load and alter pixels).
- [~] **V4** Manual VoiceOver pass on audio/colour/beauty sliders after R1 remains
  release-QA follow-up; not performed in this warning-cleanup PR and not blocking this diff.
