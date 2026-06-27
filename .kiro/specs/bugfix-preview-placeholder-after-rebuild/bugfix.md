# Bugfix: Preview Placeholder After Rebuild

> Status: **Complete**. Tracked by GitHub PR #57.

After PR #55, importing media and adding it to the timeline could leave the
preview canvas on "No Preview" even though the V1 clip was present and playback
advanced. The player item existed, but the SwiftUI preview branch did not
observe the item change.

## Regression Source

Introduced by PR #55, "Bolt: Prevent full PreviewView redraws during playback."
That PR moved high-frequency transport reads out of the parent `PreviewView`
body into `TransportOverlay`. Before PR #55, those reads incidentally caused the
parent preview canvas to re-evaluate when playback state changed. After PR #55,
the parent canvas stopped re-rendering when `AVPlayer.currentItem` changed,
exposing that `currentItem` is not an observed SwiftUI dependency.

PR #48 added the current placeholder canvas shape, but PR #55 made the defect
user-visible by removing the incidental parent invalidation.

## Bugs

### B1 - Preview canvas can stay on "No Preview" after a rebuilt player item

`PreviewView` branched on `model.player.currentItem != nil`. `AVPlayer.currentItem`
is not published through SwiftUI Observation, so replacing the item inside
`PreviewRebuildCoordinator` did not guarantee that the preview canvas switched
from the placeholder branch to the native `AVPlayerView`.

- **Fix**: Publish preview item availability through `EditorModel.hasPreviewItem`
  and route all preview item replacement through `replacePreviewItem(with:)`.
- **Regression**: Add a model-level regression that imports generated video,
  adds it to the timeline, waits for the preview rebuild, and asserts both
  `player.currentItem` and `hasPreviewItem` are present.

### B2 - New-project/session release can leave stale preview availability

Clearing the raw player item directly would bypass the observed preview state
and risk stale UI state after a new document or session release.

- **Fix**: Use `replacePreviewItem(with: nil)` from document reset/release paths
  so the observed preview state and the underlying `AVPlayer` stay synchronized.
- **Regression**: Covered by the same preview state regression and existing
  document/session reset paths.
