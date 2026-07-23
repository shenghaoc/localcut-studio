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
## 2026-07-28 - Prevent full redraws by extracting accessibility dependencies
**Learning:** Attaching accessibility modifiers (like `.accessibilityValue`) that depend on high-frequency state (`model.currentTime`) directly to an interactive `Canvas` (such as the timeline ruler) inside a large view like `TimelineView` forces the entire parent view to re-render constantly.
**Action:** Extract accessibility modifiers that track frequently changing state into isolated, invisible subviews (e.g., using `Color.clear` in an `.overlay`). This limits the `@Observable` dependency invalidation to just the lightweight overlay component, preserving the performance of the complex parent view during playback or scrubbing.
## 2026-08-01 - Isolate trace Canvas to prevent ScopesView full redraws
**Learning:** Attaching accessibility modifiers (like `.accessibilityValue`) that depend on high-frequency state (`latest`) directly to an interactive `Canvas` (such as the scope trace) inside a large view like `ScopesView` forces the entire parent view to re-render 30 times a second.
**Action:** Extract components that depend on high-frequency state into their own isolated, small views (e.g., `ScopeTraceView`). This confines the `@State` dependency tracking to only the smallest leaf nodes that actually need to re-evaluate, preserving the performance of the rest of the application layout.
## 2026-08-04 - Isolate Cover Time Label to prevent full CoverInspectorView redraws
**Learning:** Reading `model.currentTime` directly within `CoverInspectorView` to compute `coverTimeLabel` causes the entire "Cover" inspector section to unnecessarily redraw 60 times a second during playback.
**Action:** Extract specific properties into small, isolated leaf views (e.g., `CoverTimeLabelView`) so that only those narrow components re-render when the high-frequency property changes, preserving performance.
## 2026-08-04 - Isolate Overlay Keyframe Section to prevent InspectorView redraws
**Learning:** Reading `model.currentTime` via `overlayLocalPlayheadTime` within `InspectorView.body`'s call chain (through `overlayKeyframeSection`) causes the entire Inspector form to re-evaluate during playback when an overlay is selected.
**Action:** Extract the overlay keyframe section into an isolated `OverlayKeyframeSectionView` struct, following the same pattern as `CoverTimeLabelView`, so that only the leaf view re-renders when `model.currentTime` changes.

## 2026-08-08 - Isolate static grid in SpeedCurveEditor to prevent full Canvas redraws
**Learning:** Dragging handles in the `SpeedCurveEditor` updates the high-frequency state (`clip.speedCurve`), causing the entire `Canvas` (including static elements like the grid) to re-evaluate constantly. Equatable isolation must still invalidate on appearance changes when the canvas samples dynamic system colors.
**Action:** Extract static background elements (like the grid) into an isolated `Equatable` `Canvas` view layered under the dynamic components using a `ZStack`, and include `colorScheme` in the equatable inputs so light/dark switches still redraw.

## 2026-08-11 - Isolate Callout Keyframe Section to prevent ScreencastInspectorView redraws
**Learning:** Reading `model.selectedCalloutLocalPlayheadTime` directly within `ScreencastInspectorView.body`'s call chain (through `calloutKeyframeEditor`) causes the entire inspector form to re-evaluate 60 times a second during playback when a callout is selected.
**Action:** Extract the callout keyframe section into an isolated `CalloutKeyframeEditorView` struct, so that only that leaf re-renders when `model.currentTime` (via `selectedCalloutLocalPlayheadTime`) changes.
## 2026-08-20 - Batch Canvas drawing operations in Scopes
**Learning:** Creating a new `Path` and executing a `GraphicsContext.fill` call for every single data point in a dense visualisation (like a waveform or vectorscope with thousands of points) causes significant CPU overhead during 30fps/60fps redraws.
**Action:** Always batch Canvas drawing. For uniform paths (like all vectorscope dots), append to a single `Path` instance and execute one `fill`. For varying properties like opacity (as in waveform bins), quantise the property values into buckets (e.g., 64 levels) and map them to grouped `Path` instances, performing one `fill` per unique property bucket.
