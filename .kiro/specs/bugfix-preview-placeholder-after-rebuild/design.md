# Design: Preview Placeholder After Rebuild

This is a narrow preview-state bugfix. It does not change composition math,
custom compositor behavior, export behavior, timeline editing semantics, or the
visual design of the preview panel.

## Approach

Make preview item availability explicit observable state on `EditorModel`:

```swift
var hasPreviewItem = false

func replacePreviewItem(with item: AVPlayerItem?) {
    player.replaceCurrentItem(with: item)
    hasPreviewItem = item != nil
}
```

`PreviewRebuildCoordinator` and document reset/release paths call the helper
instead of mutating `player.currentItem` directly. `PreviewView` and transport
enablement then branch on `model.hasPreviewItem`, which participates in SwiftUI
Observation.

## Why not observe `AVPlayer.currentItem`

`AVPlayer.currentItem` is AVFoundation state, not an `@Observable` property on
`EditorModel`. Branching on it from SwiftUI couples view invalidation to an
implementation detail that SwiftUI does not track. Publishing a small boolean
keeps the view dependency explicit while preserving the single-player invariant
from the technical steering docs.

## HIG and UX Impact

The visible UI remains the existing native macOS preview pane:

- black letterbox background;
- native `AVPlayerView` at the view edge;
- existing "No Preview" placeholder text for genuinely empty projects;
- existing transport controls, labels, keyboard behavior, and accessibility
  values.

The user-facing improvement is material: after import and Add, the preview
switches from the placeholder to the playable video instead of leaving the user
with a false "No Preview" state.

## Architecture Boundary

The fix stays in the existing preview/orchestrator boundary:

- `EditorModel` owns the single `AVPlayer` and the observed preview state.
- `PreviewRebuildCoordinator` continues to build and install `AVPlayerItem`
  instances.
- `PreviewView` remains the only SwiftUI surface that chooses between placeholder
  and native `AVPlayerView`.

No new module, media engine, view model hierarchy, dependency, or broad refactor
is introduced for this state synchronization bug.

## Non-goals

- Forcing `containsTweening` or otherwise changing custom compositor routing.
- Adding a second `AVPlayer` or a separate preview rendering path.
- Changing export behavior or making preview/export diverge.
- Redesigning the preview panel or transport controls.
