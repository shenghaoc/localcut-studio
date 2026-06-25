# Bolt — Performance Journal

Append a dated entry whenever you learn something about keeping LocalCut Studio fast (preview fluidity, rebuild cost, decode/encode throughput, main-actor responsiveness). Format: **Learning** + **Action**.

## 2026-06-21 — Don't rebuild the whole composition on every slider tick

**Learning:** Bindings that call `EditorModel.rebuild()` (opacity, resolution, fps) rebuild the entire `AVComposition` and replace the `AVPlayerItem`. Firing that on every value of a continuous drag stutters the UI and resets playback, because each rebuild re-loads asset tracks and re-seeks.
**Action:** Apply continuous edits to the model immediately for display, but debounce/coalesce the `rebuild()` to the end of the interaction (on commit), or diff the changed clip and patch only its layer instruction once incremental rebuilds exist. Discrete changes (split/delete/add) can rebuild eagerly.

## 2026-06-21 — Thumbnails belong off the main path, batched

**Learning:** Generating bin thumbnails with a fresh `AVAssetImageGenerator` per item, synchronously, would block import and churn memory.
**Action:** Generate thumbnails asynchronously after metadata load, with a bounded `maximumSize` and `appliesPreferredTrackTransform = true`, in a detached `Task` per item; never hold the generator past the single `image(at:)` call.

## 2026-06-24 - Combine redundant pixel readback loops in ScopeSampler

**Learning:** In video processing pipelines like LocalCut Studio, multi-pass reads over frame readback buffers (like the 160x90 `ScopeReadback.pixels` array) to extract independent metrics (e.g. waveform luma and vectorscope UV offsets) redundantly traverse arrays, compute offsets, and clamp values. This harms cache locality and duplicates work for identical inputs.
**Action:** Always look for opportunities to combine pixel array traversals. Merge discrete processing loops into a single pass when extracting multiple analytical components from the same readback buffer. This shares the overhead of loop management, memory access (cache hits), array offset indexing, and channel clamping.
## 2026-06-25 - Prevent full Timeline and Preview redraws during playback
**Learning:** In SwiftUI with `@Observable` (Observation framework), reading a frequently updated property (like `AVPlayer` current time) directly within the `body` of large components like `TimelineView` (which contains complex rendering like the ruler, tracks, lanes, and clips) or `PreviewView` (which contains the `AVPlayerView` wrapper) will cause the entire view to re-render on every update frame.
**Action:** Always extract components that depend on high-frequency state into their own isolated, small views (e.g., `PlayheadView`, `TransportTimeView`). This confines the `@Observable` dependency tracking to only the smallest leaf nodes that actually need to re-evaluate, preserving the performance of the rest of the application layout.
