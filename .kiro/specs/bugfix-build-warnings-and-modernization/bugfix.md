# Bugfix: Build Warnings & Swift 6 Modernization

Zero-warning hardening pass. A clean Debug build currently emits **7 warnings** across
5 files — deprecated Core Image API, Swift 6 concurrency annotations, and a dead binding.
This spec drives the build back to zero warnings, then folds in the low-risk modernization
the user asked for: consolidating copy-pasted view/engine code and tightening the test
suite onto current Swift Testing idioms.

**Invariant: no behaviour change.** Every item here is either a warning fix, a structural
refactor that preserves output exactly, or a test-only change. The one item that touches
runtime code paths (D1, the kernel port) is a 1:1 algorithm port verified by the existing
skin-smoothing tests. Where Swift 6 / macOS 26 genuinely deprecates an API, we migrate to
the supported replacement rather than silence the diagnostic.

**Platform:** target & CI are macOS 26 (`MACOSX_DEPLOYMENT_TARGET = 26.0`); development host
is macOS 27. All replacement APIs below are available on macOS 26.

---

## Deprecations

### D1 — `CIColorKernel(source:)` deprecated (Core Image Kernel Language)

`EffectCompositor.swift:559` and `:597` build the `skinMask` and `skinBlend` colour kernels
with `CIColorKernel(source:)`, which warns:

> `'init(source:)' was deprecated in macOS 10.14: Core Image Kernel Language API deprecated.`

The CIKL (GLSL-dialect) path is the deprecated one. The supported replacement is a
Metal Shading Language kernel loaded with `CIColorKernel(functionName:fromMetalLibraryData:)`
— precompiled, so it initialises faster and gets compile-time diagnostics instead of
runtime `nil`.

- **Fix**: Port both kernels verbatim from CIKL to MSL into a `SkinSmoothKernels.ci.metal`
  source file (the `.ci.metal` suffix makes Xcode compile it with the Core Image kernel
  flags into the app's default Metal library). Load them once via
  `try CIColorKernel(functionName:fromMetalLibraryData:)` from the bundle's default
  `metallib`, keeping the existing compile-once-`static`-let shape. Surface a load failure
  through the existing `os_log(.error,…)` channel; a `nil`/throwing load degrades to the
  same "smoothing is a no-op" path the optional kernels already have.
- **Regression**: `KeyframesAndSkinSmoothTests` already exercises the skin-smooth output —
  it must stay green, confirming the MSL port matches the CIKL maths.
- **Fallback (documented, not chosen)**: defining `CI_SILENCE_GL_DEPRECATION` silences the
  warning without migrating. Rejected — it hides a real deprecation the user asked to address.

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

- **Fix**: Annotate the parameter `set: @escaping @MainActor (Double) -> Void`. `@MainActor`
  — *not* `@Sendable` — is the right tool: a global-actor-isolated closure is implicitly
  `Sendable` (satisfying `Binding.set`) while keeping the isolation the call-site closures
  need to mutate the `@MainActor` `EditorModel`. (Marking it bare `@Sendable` strips the
  isolation and the call-site `model` access fails to compile — confirmed during the build.)
  Folded into the R1 helper so the fix lands once.

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

Three near-identical slider-row builders exist with the same VStack/caption/monospaced/
accessibility shape:

- `AudioInspectorView.swift:185` — `fadeRow(label:seconds:set:)`
- `InspectorView.swift:174` — `colourSlider(label:accessibilityLabel:value:range:step:display:)`
- `InspectorView.swift:267` — `beautySlider(label:value:range:step:display:)`

- **Fix**: Extract one shared `LabeledSliderRow` view (or shared modifier) covering the
  common structure — caption row, `monospacedDigit`, `.accessibilityLabel`/`.accessibilityValue`,
  the `.accessibilityHidden(true)` on the redundant visual label (the pattern Palette's
  journal mandates). Adopt it at all three sites with their existing labels/formats intact.
  Carries the C2 `@Sendable` fix for the fade setter.

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

- **V1** — Debug/macOS build (app + tests): **zero warnings**, zero errors.
- **V2** — Full test suite green: **315 / 315** (up from 311; parameterized cases register
  individually, so no count regression).
- **V3** — Skin-smoothing output unchanged after the MSL kernel port (D1) — confirmed by
  `KeyframesAndSkinSmoothTests`.
- **V4** — Manual: inspector sliders (audio fades, colour grade, beauty) still render and
  read correctly under VoiceOver after the R1 consolidation (recommended pre-release).
