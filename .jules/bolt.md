# Bolt — Performance Journal

Append a dated entry whenever you learn something about keeping LocalCut Studio fast (preview fluidity, rebuild cost, decode/encode throughput, main-actor responsiveness). Format: **Learning** + **Action**.

## 2026-06-21 — Don't rebuild the whole composition on every slider tick

**Learning:** Bindings that call `EditorModel.rebuild()` (opacity, resolution, fps) rebuild the entire `AVComposition` and replace the `AVPlayerItem`. Firing that on every value of a continuous drag stutters the UI and resets playback, because each rebuild re-loads asset tracks and re-seeks.
**Action:** Apply continuous edits to the model immediately for display, but debounce/coalesce the `rebuild()` to the end of the interaction (on commit), or diff the changed clip and patch only its layer instruction once incremental rebuilds exist. Discrete changes (split/delete/add) can rebuild eagerly.

## 2026-06-21 — Thumbnails belong off the main path, batched

**Learning:** Generating bin thumbnails with a fresh `AVAssetImageGenerator` per item, synchronously, would block import and churn memory.
**Action:** Generate thumbnails asynchronously after metadata load, with a bounded `maximumSize` and `appliesPreferredTrackTransform = true`, in a detached `Task` per item; never hold the generator past the single `image(at:)` call.

## 2026-06-23 — Core Image kernels: Metal Shading Language, not CIKL

**Learning:** The skin-smoothing kernels used `CIColorKernel(source:)` (Core Image Kernel Language, deprecated since macOS 10.14). CIKL kernels compile at runtime on first use; MSL kernels are precompiled into the app's default `metallib`, so they initialise faster and surface errors at build time instead of returning `nil` at runtime.
**Action:** Author Core Image kernels in a `*.ci.metal` file. The `.ci.metal` suffix + the project's synchronized file-system group (objectVersion 90 / Xcode 26) make Xcode apply the CI kernel build flags automatically — no pbxproj/per-file flag surgery. Load via `try CIColorKernel(functionName:fromMetalLibraryData:)` from `Bundle.main.url(forResource: "default", withExtension: "metallib")`, keep the compiled kernel in a `static let`, and degrade to a logged no-op if the load throws.
