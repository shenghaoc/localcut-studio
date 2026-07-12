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
## 2026-07-05 - Isolate high-frequency @Observable updates in recording UI
**Learning:** Reading high-frequency `@Observable` properties like `recordingElapsedSeconds` and `recordingMicLevel` directly in the main `body` of large views (`ContentView`, `RecorderFloatingPanelContent`) causes the entire parent view to re-render continually during recording, wasting CPU and battery.
**Action:** Extract specific properties into small, isolated leaf views (e.g., `RecordingElapsedView`, `PanelMicLevelMeterView`) so that only those narrow components re-render when the property changes, preserving performance across the broader application UI.
## 2026-07-10 - Avoid redundant Canvas rendering for static background elements
**Learning:** SwiftUI `Canvas` drawing closures re-execute entirely when any captured state changes. If a `Canvas` captures a high-frequency property (like a 30fps scope trace sample), expensive static layout operations like drawing text labels and complex background grids are unnecessarily re-computed on every frame, consuming excess CPU.
**Action:** Separate static background elements (graticule lines, target boxes, text labels) and dynamic trace elements into separate `Canvas` views layered within a `ZStack`. Extract the background `Canvas` into an `Equatable` child view (e.g. `ScopeBackgroundCanvas`) so SwiftUI's diffing skips it entirely when only the high-frequency property changes — a plain `Canvas` in the parent body would still re-execute its closure on every parent re-evaluation.
## 2026-07-12 - Extract timeline ruler Canvas to Equatable background view
**Learning:** The TimelineView re-evaluates on every scroll frame due to its timelineCurrentScrollSeconds state. The ruler Canvas redrew thousands of ticks and beat markers needlessly.
**Action:** Extract static canvas elements (like timeline ticks and beat markers) into an `Equatable` view when they are inside a view that re-evaluates frequently (like scrolling).
