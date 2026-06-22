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

## Key technical decisions

### Core Image kernel migration (D1)

The deprecated `CIColorKernel(source:)` takes Core Image Kernel Language (a GLSL dialect).
The supported path on macOS 26 is **Metal Shading Language**, loaded via
`CIColorKernel(functionName:fromMetalLibraryData:)`. MSL kernels are precompiled, so they
init faster and surface errors at *build* time instead of returning `nil` at runtime.

- Add `SkinSmoothKernels.ci.metal`. The `.ci.metal` extension makes Xcode apply the Core
  Image kernel compiler/linker flags and emit the kernels into the app's default Metal
  library — no manual `OTHER_METAL_COMPILER_FLAGS`/`MTLLINKER_FLAGS` editing if the suffix
  convention is honoured; verify the flags are present after adding the file.
- Port `skinMask` and `skinBlend` line-for-line: CIKL `__sample`/`vec4` → MSL
  `sample_t`/`float4`, wrapped in `extern "C" { namespace coreimage { … } }` with
  `#include <CoreImage/CoreImage.h>`. The maths (YCbCr skin probability, `mix` blend) is
  identical.
- Load once into the existing `static let` slots from
  `Bundle.main.url(forResource: "default", withExtension: "metallib")` → `Data` →
  `try CIColorKernel(functionName:…)`. A throw/`nil` logs via the existing `os_log` channel
  and leaves smoothing as a no-op — the same degradation the optional kernels already model.

This is the only change touching a runtime render path; `KeyframesAndSkinSmoothTests` is the
oracle that the port is exact.

### Concurrency annotations (C1–C3)

These are SDK-driven: the macOS 26 SDK tightened `@Sendable` on `Binding.set` and on the
`requestMediaDataWhenReady` block. None reflect a real data race — they're missing
annotations on already-safe code.

- **C1**: drop the now-redundant `(unsafe)`; the type's `@unchecked Sendable` conformance
  carries the proof.
- **C2**: propagate `@Sendable` onto the `set` parameter — it flows straight into a
  `@Sendable` setter.
- **C3**: the request block runs only on the serial `pumpQueue` with sole ownership of the
  input/output, so a documented `@unchecked Sendable` confinement (sibling to the file's
  existing `ResumeBox`) is the correct, minimal expression of that invariant.

### Consolidation safety (R1–R3)

Extractions only. R1 unifies three slider helpers behind one view, preserving each call
site's labels, value formats, and the `.accessibilityHidden(true)` / `.accessibilityValue`
pairing the accessibility journal requires — and absorbs C2 in one place. R2 and R3 remove
plumbing while leaving the per-call parameters and lifetimes identical. R4 is **not** done.

### Test idioms (T1–T3)

`try #require` converts run-aborting force-unwraps into localized failures; parameterized
`@Test(arguments:)` turns case families into navigator-visible rows. Coverage is preserved
or increased; the suite must stay green with no count regression.

## Out of scope

- Composition track-insertion dedup (R4) — deferred, see `bugfix.md`.
- Any product behaviour, UI layout, or rendered-output change.
- New entitlements, dependencies, or build configurations beyond the `.ci.metal` source the
  kernel migration requires.
