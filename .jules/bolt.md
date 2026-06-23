# Bolt — Performance Journal

Append a dated entry whenever you learn something about keeping LocalCut Studio fast (preview fluidity, rebuild cost, decode/encode throughput, main-actor responsiveness). Format: **Learning** + **Action**.

## 2026-06-21 — Don't rebuild the whole composition on every slider tick

**Learning:** Bindings that call `EditorModel.rebuild()` (opacity, resolution, fps) rebuild the entire `AVComposition` and replace the `AVPlayerItem`. Firing that on every value of a continuous drag stutters the UI and resets playback, because each rebuild re-loads asset tracks and re-seeks.
**Action:** Apply continuous edits to the model immediately for display, but debounce/coalesce the `rebuild()` to the end of the interaction (on commit), or diff the changed clip and patch only its layer instruction once incremental rebuilds exist. Discrete changes (split/delete/add) can rebuild eagerly.

## 2026-06-21 — Thumbnails belong off the main path, batched

**Learning:** Generating bin thumbnails with a fresh `AVAssetImageGenerator` per item, synchronously, would block import and churn memory.
**Action:** Generate thumbnails asynchronously after metadata load, with a bounded `maximumSize` and `appliesPreferredTrackTransform = true`, in a detached `Task` per item; never hold the generator past the single `image(at:)` call.
