# Design: Build Warnings & Swift 6 Modernization

A hygiene pass, not a feature. Grounded in the **actual** warnings a clean Debug build emits
today (captured via the Xcode build log, not inferred): 7 warnings across `EffectCompositor`,
`ScopeSampler`, `AudioInspectorView`, `Models`, and `RenderQueue`. No new dependencies, no
architecture change, no behaviour change.

## Approach

Three concentric rings, each gated on the previous staying green:

1. **Silence the build legitimately** (D1, C1–C3, W1) — fix the root cause of every warning,
   never `#pragma`/define it away. Where the API is genuinely deprecated, migrate to the
   supported successor.
2. **Consolidate duplication** (R1–R3) — behaviour-preserving extraction of copy-pasted
   view and engine code the user called out. R4 (composition loops) is consciously deferred
   as too P0-sensitive for a cleanup pass.
3. **Modernize tests** (T1–T3) — adopt current Swift Testing idioms (`#require`,
   parameterized `@Test`) without dropping coverage.

## PR #93 follow-up design

The follow-up sweep keeps the same no-behaviour-change constraint and uses four narrow rules:

1. Replace remaining manual `NSLock` ownership in the affected source and test helpers with
   immutable `OSAllocatedUnfairLock` instances. Cache dictionaries and LRU order arrays move
   into the lock's state value so mutation cannot escape the critical section.
2. Use `withLock` for compiler-verifiable values and `withLockUnchecked` only where the closure
   carries SDK types that are not consistently `Sendable` across the macOS 26 and 27 toolchains
   (`CVPixelBuffer`, `CMSampleBuffer`, and WebRTC delegates/sources).
3. Snapshot state under the lock, then invoke callbacks, render work, `cancelWriting`, and
   `finishWriting` outside it. This preserves the existing serialization without extending
   lock hold times around framework calls.
4. Add `Sendable` only to stateless namespace enums, error enums with `Sendable` payloads, and
   value types whose stored properties are already `Sendable`. Replace deprecated file-URL
   initializers without changing path inputs or directory hints.

After merging current `main`, actor-owned state remains actor-owned. In particular,
`WhipSession.stateStream` keeps `main`'s actor-isolated cache rather than retaining the earlier
lock workaround for a now-removed `nonisolated(unsafe)` access path.

The final clean-build pass also removes a no-op `await`, explicitly matches the weak
`EditorModel` capture at both the SwiftUI action and nested `Task` levels, and makes discarded
dictionary-removal results explicit inside lock closures. These changes preserve action flow,
task lifetime, and lock ownership while satisfying Swift 6 diagnostics.

## Key technical decisions

### Core Image kernel migration (D1)

The deprecated `CIColorKernel(source:)` takes Core Image Kernel Language (a GLSL dialect).
The shipped path uses **Metal Shading Language** source compiled once at runtime with
`CIKernel.kernels(withMetalString:)`. A precompiled `.ci.metal` → `default.metallib` attempt
was abandoned because the synchronized file-system group did not reliably thread the Metal
`-cikernel` link flag, leaving the kernels absent from `default.metallib` in CI.

- Port `skinMask` and `skinBlend` line-for-line from CIKL to Metal Shading Language (MSL)
  as a runtime string, wrapped in `extern "C" { namespace coreimage { ... } }` with
  `#include <CoreImage/CoreImage.h>`. The maths (YCbCr skin probability, mix blend) is
  identical.
- Compile once at runtime via `CIKernel.kernels(withMetalString:)` and load into the
  `static let` slots. A throw/`nil` logs via the existing `os_log` channel and leaves
  smoothing as a no-op — the same degradation the optional kernels already model. This
  runtime string compilation avoids build-system complexity around precompiled
  `.ci.metal` files and works in app, test-host, and CI bundle contexts.

This is the only change touching a runtime render path; `KeyframesAndSkinSmoothTests` is the
oracle that the port is exact and includes a render-path assertion that the compiled kernels
alter a skin-tone fixture.

### Concurrency annotations (C1–C3)

These are SDK-driven: the macOS 26 SDK tightened `@Sendable` on `Binding.set` and on the
`requestMediaDataWhenReady` block. None reflect a real data race — they're missing
annotations on already-safe code.

- **C1**: drop the now-redundant `(unsafe)`; the type's `@unchecked Sendable` conformance
  carries the proof.
- **C2**: build the fade `Binding<Double>` inline in a `fadeBinding(_:)` helper (matching the
  `masterGainBinding` shape) so the setter's main-actor isolation is inferred. Do not forward
  an annotated closure; the interim `@MainActor` closure form crashed Swift 6.3.2 on CI.
- **C3**: the request block runs only on the serial `pumpQueue` with sole ownership of the
  input/output, so a documented `@unchecked Sendable` confinement (sibling to the file's
  existing `ResumeBox`) is the correct, minimal expression of that invariant.

### Consolidation safety (R1–R3)

Extractions only. R1 unifies the repeated inspector slider layouts behind one view: clip
opacity, transition duration, colour grade, beauty, track gain, and clip fades. It preserves
each call site's labels, value formats, and `.accessibilityHidden(true)` /
`.accessibilityValue` pairing; `.inline` captions carry `.monospacedDigit()` so numeric
values do not jitter while scrubbing. R2 removes colour-grade filter plumbing while leaving
the per-call parameters identical. R3 and R4 are **not** done.

### Test idioms (T1–T3)

`try #require` converts run-aborting force-unwraps into localized failures; parameterized
`@Test(arguments:)` turns case families into navigator-visible rows. Coverage is preserved
or increased; the suite must stay green with no count regression.

## Out of scope

- Composition track-insertion dedup (R4) — deferred, see `bugfix.md`.
- Any product behaviour, UI layout, or rendered-output change.
- New entitlements, dependencies, or build configurations; the runtime MSL string keeps the
  kernel migration out of project build settings.
