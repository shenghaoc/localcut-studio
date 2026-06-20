---
name: swiftui-patterns
description: SwiftUI + Observation conventions for LocalCut Studio. Use when editing *View.swift, wiring EditorModel state, or building reactive timeline/inspector controls.
metadata:
  version: "1.0.0"
---

# SwiftUI Patterns — LocalCut Studio

This app uses SwiftUI with the **Observation** framework on a target whose default actor isolation is `MainActor`. All media work funnels through `EditorModel`; views send intents and read state.

## Rules

1. **One source of truth** — `EditorModel` (`@Observable @MainActor`) owns the `Project`, the single `AVPlayer`, selection, and timeline view state. Views never instantiate their own player or composition.
2. **State ownership** — the root `EditorView` holds the model with `@State private var model = EditorModel()`. Child views take it as `@Bindable var model: EditorModel` so they can bind (`$model.pixelsPerSecond`) without re-creating it.
3. **No AVFoundation in views** — except the wrapped `AVPlayerView` (`PreviewPlayerView: NSViewRepresentable`). Everything else goes through the model.
4. **Intents, not mutation** — views call `model.addToTimeline(...)`, `model.splitSelectedClipAtPlayhead()`, etc. The model mutates the `Project` and triggers `rebuild()`.
5. **Coalesce expensive bindings** — a binding that causes a composition rebuild (opacity, resolution, fps) is fine for discrete changes; for continuous drags, debounce or apply on commit so you don't rebuild every tick.
6. **Cleanup** — register periodic time / notification observers in the model's `init`, tear down in `deinit`; `[weak self]` inside their closures and inside any `Task` the model owns.
7. **AppKit at the edge** — wrap `AVPlayerView` and present `NSSavePanel`/`NSOpenPanel` (or `.fileImporter`) only at the boundary; keep the rest pure SwiftUI.

## Model ↔ view flow

```swift
// View sends intent
model.addToTimeline(mediaID: item.id)        // mutates Project, calls rebuild()

// View reads low-frequency state
model.currentTime    // updated by AVPlayer periodic observer
model.statusMessage  // background work + errors
model.totalDuration  // set after each rebuild
```

The periodic time observer is the analogue of the browser project's shared-clock: the model updates `currentTime`; the timeline playhead and transport read it. Do not poll the player from views.

## File placement

| Concern | Location |
|---------|----------|
| Layout, panels, transport | `LocalCut Studio/*View.swift` |
| State, intents, playback, export | `LocalCut Studio/EditorModel.swift` |
| Model types | `LocalCut Studio/Models.swift` |
| Composition / transforms | `LocalCut Studio/CompositionBuilder.swift` |
