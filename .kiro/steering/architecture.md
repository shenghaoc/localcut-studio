# Architecture

## Overview

LocalCut Studio is a single-window SwiftUI app over an AVFoundation editing core. The data model is the source of truth; whenever it changes, the engine rebuilds an immutable `AVComposition` + `AVVideoComposition` that drives **both** preview (`AVPlayerItem`) and export (`AVAssetExportSession` / `AVAssetWriter`).

```
SwiftUI views ──▶ EditorModel (@Observable, @MainActor)
                      │  owns Project (model), AVPlayer, selection, timeline view state
                      ▼
              CompositionBuilder  ──▶  AVComposition + AVVideoComposition
                      │                         │
            AVPlayerItem (preview)       AVAssetExportSession (export)
```

## Mapping from the browser original

| Browser-editor | Native macOS |
|---|---|
| WebCodecs / Mediabunny (demux/mux) | AVFoundation / VideoToolbox |
| WebGPU preview pipeline | Metal / Core Image, via `AVVideoCompositing` |
| Multi-track compositing | `AVMutableComposition` + `AVMutableVideoComposition` layer instructions |
| GPU effect chain (WGSL) | Core Image filters / Metal kernels in a custom compositor |
| Export (H.264/VP9/AV1) | `AVAssetExportSession` / `AVAssetWriter` (H.264/HEVC/ProRes) |
| SolidJS UI + SAB clock | SwiftUI + `AVPlayer` periodic time observer |

## Layers

- **Model** (`Models.swift`) — `MediaItem`, `Clip`, `Track`, `Project`. Plain value/observable types; no AVFoundation side effects beyond holding an `AVURLAsset`.
- **Engine** (`CompositionBuilder.swift`, later a custom compositor + exporter) — pure-ish translation from `Project` to AVFoundation objects. No SwiftUI.
- **Orchestrator** (`EditorModel.swift`) — `@Observable @MainActor`; import, timeline mutations, playback transport, rebuild, export. Holds the only `AVPlayer`.
- **Views** (`*View.swift`) — SwiftUI; read the model, send intents. AppKit interop (`AVPlayerView`, `NSSavePanel`) wrapped at the edge.

## Render path invariant

Preview and export read the **same** `BuiltComposition`. A new effect or transition is added once, in `CompositionBuilder` (or the custom compositor), so it appears identically in both. Diverging the two paths is a P0 review failure.

## Development phases

1. **Foundation** *(done)* — import, multi-track timeline, preview, split/delete, opacity, export.
2. **Colour grading** — Core Image/Metal effect chain via custom `AVVideoCompositing`.
3. **Trim & drag** — direct-manipulation clip editing with snapping.
4. **Transitions** — cross-dissolve/wipe between adjacent clips.
5. **Persistence** — Codable document, security-scoped bookmarks, undo/redo.
6. **Audio** — waveforms, gain/pan, fades, master bus.
7. **Titles/text**, **export expansion** (HEVC/ProRes, bitrate/range), **render queue**.
