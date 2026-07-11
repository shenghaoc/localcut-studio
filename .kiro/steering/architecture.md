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

- **Portable domain** (`Packages/LocalCutCore/Sources/LocalCutDomain`) —
  Foundation-only value types, policies, and algorithms. Built and tested on
  macOS and Linux. It never imports Apple media or UI frameworks.
- **Apple media core** (`Packages/LocalCutCore/Sources/LocalCutCore`) —
  deterministic non-UI code that legitimately uses CoreMedia, CoreGraphics,
  CoreVideo, Accelerate, VideoToolbox, Observation, or `os`. It never imports
  SwiftUI, AppKit, AVKit, or AVFoundation.
- **macOS platform/app layer** (`LocalCut Studio/`) — AVFoundation, Metal,
  WebRTC, Lottie, security-scoped resources, orchestration, and framework
  adapters. Non-UI code belongs here whenever it needs these macOS-only APIs.
- **Views** (`*View.swift`) — SwiftUI; read models and send intents. AppKit
  interop (`AVPlayerView`, `NSSavePanel`) stays at the edge.

This is a dependency direction, not a claim that every non-view type is
portable: app → Apple media core → portable domain, never the reverse.

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
