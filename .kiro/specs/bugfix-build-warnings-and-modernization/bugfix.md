# Bugfix: Build Warnings & Swift 6 Modernization

Zero-warning hardening pass. A clean Debug build emits **7 warnings** across 5 files locally
(deprecated Core Image API, Swift 6 concurrency annotations, a dead binding) plus a macOS 26
**deprecation that only surfaces on CI's Xcode 26.5** (`AVMutableVideoCompositionLayerInstruction`,
D2). This spec drives the build back to zero warnings on **both** the macOS 27 dev host and the
macOS 26 CI toolchain, then folds in the low-risk modernization the user asked for:
consolidating copy-pasted view/engine code and tightening the test suite onto current Swift
Testing idioms.

**Invariant: no behaviour change.** Every item here is either a warning fix, a structural
refactor that preserves output exactly, or a test-only change. The one item that touches
runtime code paths (D1, the kernel port) is a 1:1 algorithm port verified by the existing
skin-smoothing tests. Where Swift 6 / macOS 26 genuinely deprecates an API, we migrate to
the supported replacement rather than silence the diagnostic.

**Platform:** target & CI are macOS 26 (`MACOSX_DEPLOYMENT_TARGET = 26.0`); development host
is macOS 27. All replacement APIs below are available on macOS 26.

---

## Follow-up Swift 6 sweep (PR #93)

PR #93 extends the original warning cleanup without changing product behaviour. The remaining
modernization debt was spread across lock-protected media paths, namespace/value types crossing
concurrency boundaries, and deprecated file-URL construction in tests and two source helpers.

- **Root cause:** several components still used manual `NSLock` state alongside Swift 6
  `@Sendable` closures, while otherwise-safe namespace/value types lacked explicit `Sendable`
  conformance. Test fixtures and two source helpers still used `URL(fileURLWithPath:)`.
- **Expected behaviour:** frame caches, capture writers, live/program compositors, and WebRTC
  taps preserve their existing serialization and output. Non-`Sendable` Core Video, Core Media,
  and WebRTC values use `withLockUnchecked`; callbacks and writer completion work stay outside
  critical sections. No UI, persistence schema, render result, or user flow changes.
- **Main-sync decision:** current `main` already actor-isolates `WhipSession.stateStream`, so the
  PR's older extra stream-cache lock is intentionally superseded by that stronger actor-owned
  implementation. Current `main` lifetime comments and the non-WebRTC `VideoPublishTap` storage
  accessor are retained while their locks are modernized.
- **Regression path:** the LocalCutCore package suite and full macOS Xcode suite cover the
  affected model, capture, compositor, overlay-cache, replay-buffer, and publish paths. The
  effective post-merge diff adds no user-facing UI.
- **Final warning closure:** the post-merge build also surfaced a no-op `await` in the caption
  filler, nested SwiftUI action/`Task` capture-ownership diagnostics, and an intentionally
  discarded lock-closure result. These are corrected in the same hygiene pass; the weak captures
  still avoid retaining `EditorModel` for the lifetime of an asynchronous action.
- **CI retry recovery:** Xcode records a Swift Testing failure's test target separately from its
  suite/test identifier. The flake-detection wrapper now reads that target from the result bundle
  before issuing `-only-testing:` retries. The App Intents cancellation assertion keeps its
  one-second bound against a deliberately 60-second predecessor, avoiding scheduler-sensitive
  false failures without weakening the cancellation guarantee.

---

## Deprecations

### D1 — `CIColorKernel(source:)` deprecated (Core Image Kernel Language)

`EffectCompositor.swift:559` and `:597` build the `skinMask` and `skinBlend` colour kernels
with `CIColorKernel(source:)`, which warns:

> `'init(source:)' was deprecated in macOS 10.14: Core Image Kernel Language API deprecated.`

The CIKL (GLSL-dialect) path is the deprecated one. The shipped replacement is Metal
Shading Language source compiled once at runtime with `CIKernel.kernels(withMetalString:)`.
That keeps the algorithm on the supported MSL path while avoiding the precompiled
`.ci.metal` build-flag problem described below.

- **Fix (as shipped)**: Port both kernels verbatim from CIKL to **`[[ stitchable ]]` Metal
  Shading Language**, compiled once at runtime via `CIKernel.kernels(withMetalString:)`,
  keeping the compile-once-`static`-let shape. A load/compile failure logs via
  `os_log(.error,…)` and degrades to the existing "smoothing is a no-op" path.
  - *First attempt (abandoned):* a precompiled `SkinSmoothKernels.ci.metal` →
    `default.metallib` loaded with `CIColorKernel(functionName:fromMetalLibraryData:)`. The
    project's synchronized file-system group never threaded the Metal `-cikernel` link flag,
    so the kernels weren't in `default.metallib` and `applySkinSmooth` silently no-op'd. The
    runtime-string path needs no build-flag plumbing and works in every bundle context.
- **Regression**: `skinSmoothRenderPathAltersPixels` renders a skin-tone fixture *through the
  compiled kernels* and asserts pixels change — it caught the silent no-op above and guards
  against a missing/renamed kernel that the model-only tests miss. `applySkinSmooth` is
  `internal` for the test.
- **Fallback (documented, not chosen)**: defining `CI_SILENCE_GL_DEPRECATION` silences the
  warning without migrating. Rejected — it hides a real deprecation the user asked to address.

### D2 — `AVMutableVideoCompositionLayerInstruction` deprecated (macOS 26)

`CompositionBuilder.crossDissolveLayerInstructions` built two
`AVMutableVideoCompositionLayerInstruction`s with `setTransform`/`setOpacityRamp`. The whole
mutable class is deprecated in the macOS 26 SDK (only surfaced on CI's Xcode 26.5, not the
macOS 27 dev host):

> `'AVMutableVideoCompositionLayerInstruction' was deprecated in macOS 26.0: Use AVVideoCompositionLayerInstruction.Configuration instead`

- **Fix**: Build each instruction from an `AVVideoCompositionLayerInstruction.Configuration`
  (`init(trackID:)` + `setTransform(_:at:)` + `addOpacityRamp(_:)`) and return the immutable
  `AVVideoCompositionLayerInstruction(configuration:)`. The regression test reads ramps via
  the modern `opacityRamp(at:)` (a returned struct) instead of the out-param `getOpacityRamp`.
  No behaviour change — same trackID, transform, and 1→0 / 0→1 opacity ramp.

---

## Swift 6 concurrency warnings

### C1 — `nonisolated(unsafe)` no longer needed on `ScopeSampler.shared`

`ScopeSampler.swift:52`:

> `'nonisolated(unsafe)' is unnecessary for a constant with 'Sendable' type 'ScopeSampler', consider removing it`

`ScopeSampler` is `@unchecked Sendable` with all-nonisolated accessors, so the compiler now
proves the singleton safe under plain `nonisolated`; the `(unsafe)` escape hatch is dead.

- **Fix**: `nonisolated(unsafe) static let shared` → `nonisolated static let shared`. The
  static must stay `nonisolated` (the compositor reaches it off the main actor) — only the
  `(unsafe)` qualifier is dropped.

### C2 — Non-`Sendable` closure passed where `@Sendable` is expected

`AudioInspectorView.swift:200`:

> `Passing non-Sendable parameter 'set' to function expecting a '@Sendable' closure`

`fadeRow(label:seconds:set:)` forwards its `set: @escaping (Double) -> Void` into
`Binding(get:set:)`, whose setter is now `@Sendable` in the SDK.

- **Fix (as shipped)**: Build the `Binding<Double>` **inline** in a `fadeBinding(_:)` helper
  (the same shape as the existing `masterGainBinding`) so the setter's main-actor isolation is
  *inferred* — no isolation-annotated closure is forwarded at all.
  - *Interim attempt (reverted):* annotating the forwarded parameter `@escaping @MainActor
    (Double) -> Void` silenced the warning on the macOS 27 host, but **crashed the Swift 6.3.2
    compiler on CI** (Xcode 26.5) in IRGen while emitting the `@MainActor`→`@Sendable`
    reabstraction thunk for `Binding.set`. Building the binding inline sidesteps the thunk
    entirely (see CI-crash note below).

### C3 — Non-`Sendable` AVFoundation captures in `@Sendable` request block

`RenderQueue.swift:708` and `:709`:

> `Capture of 'input' with non-Sendable type 'AVAssetWriterInput' in a '@Sendable' closure`
> `Capture of 'output' with non-Sendable type 'AVAssetReaderOutput' in a '@Sendable' closure`

`pump(...)` passes a block to `input.requestMediaDataWhenReady(on:using:)`, whose block is
`@Sendable` in the SDK. `AVAssetWriterInput` / `AVAssetReaderOutput` aren't `Sendable`, but
the block only ever runs on the single serial `pumpQueue` and the input/output are confined
to this one pump — no concurrent access actually occurs.

- **Fix**: Confine the two references in a small `@unchecked Sendable` box (or
  `nonisolated(unsafe)` locals) whose comment documents the serial-queue invariant that
  makes the capture safe, mirroring the existing `ResumeBox` pattern already in this file.
  No behaviour change — the same objects run on the same queue.

---

## Dead-code warning

### W1 — Unused binding in `Keyframes.updateKeyframe`

`Models.swift:507`:

> `Value 'i' was defined but never used; consider replacing with boolean test`

`guard let i = keyframes.firstIndex(where: { $0.id == id })` binds `i`, but the index is
re-derived as `j` after the dedup `removeAll`, so `i` is dead.

- **Fix**: `guard keyframes.contains(where: { $0.id == id }) else { return }`. Pure
  presence-check; the real index work stays at the `j` lookup.

---

## Consolidation (redundant code)

> Behaviour-preserving refactors. Each must keep the exact rendered output, accessibility
> labels/values, and composition maths it replaces. Gated on the test suite staying green.

### R1 — Unify inspector "labeled slider row" helpers

Several inspector slider layouts had converged on the same VStack/caption/monospaced/
accessibility shape, but implemented it independently:

- `InspectorView.swift` — clip opacity, transition duration, colour grade, and beauty sliders
- `AudioInspectorView.swift` — track gain and clip fade sliders

- **Fix (as shipped)**: Extract one shared `LabeledSliderRow` view covering the common
  structure — caption row, `monospacedDigit`, `.accessibilityLabel`/`.accessibilityValue`,
  and `.accessibilityHidden(true)` on redundant inline visual labels. Adopt it across the
  inspector with the existing labels/formats intact. The `.inline` caption applies
  `.monospacedDigit()` directly to the caption text, addressing Claude's P2 jitter comment;
  the fade rows feed it a `Binding<Double>` built inline per C2.

### R2 — Collapse colour-grade `CIFilter` boilerplate

`EffectCompositor.swift:526–553` repeats `if changed { let f = CIFilter.x(); f.inputImage =
result; …; result = f.outputImage ?? result }` for exposure, contrast/saturation, and
temperature/tint.

- **Fix**: A small private `apply(_ filter: CIFilter, when condition: Bool) -> CIImage`
  helper (or `result = result.applying { … }` closure form) that binds `inputImage`, pulls
  `outputImage`, and falls back to the prior image. Keeps the per-filter parameter wiring;
  removes the repeated plumbing.

### R3 — (Deferred) Security-scoped-access helper

The acquire/`defer`-release dance repeats at `RenderQueueInspectorView.swift:165`,
`RenderQueue.swift:371`, and `RenderQueue.swift:989`.

- **Decision**: **Deferred.** The pattern is a 2-line idiom wrapped around large
  multi-`return` bodies (panel flow, job runner). A `withSecurityScopedAccess { … }` closure
  would force those bodies inside the closure and obscure their control flow for no warning
  benefit. The inline `start` + `defer stop` is already the clear, idiomatic form; left as-is.

### R4 — (Optional, deferred) Composition track-insertion loops

`CompositionBuilder.swift:147` (video, with transition-pool reuse) and `:207` (audio) share
an `addMutableTrack` + `insertTimeRange` shape but differ materially in the pooling logic.

- **Decision**: **Defer.** Composition time-range maths is P0-sensitive (per the review
  checklist) and the two loops aren't truly identical. Not worth the regression risk in a
  warning-cleanup pass. Listed only so a reviewer knows it was considered and consciously
  left alone.

---

## Test modernization

> Test-only. All 18 test files already use Swift Testing (no XCTest). These adopt newer
> idioms; the test count must not drop.

### T1 — `try #require` instead of force-unwrap

Force-unwraps that crash the whole run on failure instead of failing one test cleanly:

- `TransitionsTests.swift:87–88, 102, 104, 109, 118, 130` (`placements.first { … }!`,
  `pb.transitionRange!`)
- `TrimAndDragTests.swift:282, 318, 367` (`model.project.videoTracks.first!`)

- **Fix**: Replace each `!` with `try #require(…)` in a `throws` test.
  `TransitionsIntegrationTests.swift:73` already models this.

### T2 — (Not done) `guard case … Issue.record(…)` conversions

The `guard case .x(let v) = effect else { Issue.record(…); return }` shape recurs across
several test files.

- **Decision**: **Left as-is.** Swift Testing has no case-pattern `#require`; converting these
  needs an awkward `try #require({ if case … { return v } else { return nil } }())` wrapper
  that reads worse than the `guard case` it replaces. The `guard case` + `Issue.record` form
  is the idiomatic Swift Testing way to assert an enum case, so it stays.

### T3 — Parameterize repetitive cases with `@Test(arguments:)`

- `CaptionTailFillerTests.swift:15–28` — tolerance/duration cases differing only by inputs.
- `KeyframesAndSkinSmoothTests.swift:8–55` — interpolation cases over varying times.

- **Fix**: Fold each family into one `@Test(arguments:)` parameterized test so cases show
  up individually in the navigator and a new case is one tuple, not a new function. Net test
  *coverage* must not decrease.

---

## Verification

- **V1** — Debug/macOS build (app + tests): **zero warnings**, zero errors on **both** the
  macOS 27 dev host and the macOS 26 / Xcode 26.5 CI toolchain (D2 only surfaced on CI).
- **V2** — Full test suite green: **320 / 320** (parameterized cases + the render-path test
  register individually; no count regression).
- **V3** — Skin-smoothing render path verified end-to-end by `skinSmoothRenderPathAltersPixels`
  (compiled kernels load and alter pixels).
- **V4** — Manual: inspector sliders (audio fades, colour grade, beauty) still render and
  read correctly under VoiceOver after the R1 consolidation (recommended pre-release).

---

## CI / toolchain notes

The dev host is macOS 27 / Xcode 27 (Swift 6.4); CI and the deployment target are macOS 26 /
Xcode 26.5 (Swift 6.3.2). Two issues only reproduced on the CI toolchain:

- **Compiler crash (C2):** the interim `@MainActor`-annotated `Binding.set` closure crashed
  Swift 6.3.2 in IRGen (reabstraction thunk `@$sSdScA_pSgIeAghyg_SdIeAghn_TR`). Building the
  binding inline avoids the thunk. Don't reintroduce isolation-annotated closures forwarded
  into `Binding(get:set:)`.
- **macOS 26 deprecation (D2):** `AVMutableVideoCompositionLayerInstruction` is only flagged
  deprecated by the macOS 26 SDK, so it was invisible on the dev host. Treat the CI build log
  as the authoritative zero-warning gate — a clean local build isn't sufficient.
