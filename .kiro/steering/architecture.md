# Architecture

## Overview

LocalCut Studio is a SwiftUI app over an AVFoundation editing core. On the
current macOS 26 baseline, its custom URL-based document controller owns one
live editor session rather than a `DocumentGroup` document scene. The data
model is the source of truth; whenever it changes, the engine rebuilds an
immutable `AVComposition` + `AVVideoComposition` that drives **both** preview
(`AVPlayerItem`) and export (`AVAssetExportSession` / `AVAssetWriter`).

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
- **macOS platform layer** (`Packages/LocalCutCore/Sources/LocalCutPlatform`) —
  presentation-independent adapters for AVFoundation, ScreenCaptureKit, Metal,
  WebRTC, Lottie, capture, publishing, and media decoding. This target exists
  only in the macOS package graph and depends on `LocalCutCore`, never the app.
- **App orchestration** (`LocalCut Studio/`) — `EditorModel`, project/document
  lifecycle, composition/export coordination, security-scoped resources, and
  presentation state. It consumes the platform layer and owns no direct
  WebRTC, ScreenCaptureKit, or Lottie integration.
- **Views** (`*View.swift`) — SwiftUI; read models and send intents. AppKit
  interop (`AVPlayerView`, `NSSavePanel`) stays at the edge.

This is a dependency direction, not a claim that every non-view type is
portable: app → macOS platform → Apple media core → portable domain, never the
reverse.

## Document and window lifecycle

`DocumentController` remains the document owner at the macOS 26 deployment
target. It has the selected URL needed for asynchronous load/relink/rebuild,
atomic `.lcstudio` and `.lcbundle` writes, package staging/fingerprints, and
security-scoped resource lifetime. `EditorModel` owns the document's live
AVFoundation/editor state (including its one `AVPlayer`), undo manager, capture
state, and render queue.

The native-document-lifecycle spike verified that `ReferenceFileDocument` can
represent a flat file or `FileWrapper` package, but its macOS 26 callbacks are
synchronous and wrapper-based. It cannot preserve the URL-backed streaming
transaction without duplicating or degrading the persistence layer, so the app
does not use `DocumentGroup` until the deployment target can prove the newer
asynchronous URL document APIs equivalent. See
[`feature-native-document-lifecycle`](../specs/feature-native-document-lifecycle/design.md).

Window presentation state belongs to SwiftUI scenes where possible: inspector
visibility uses `@SceneStorage`, focused bindings route the View menu to the key
scene, and scene placement/restoration own new-window geometry. The narrow
`WindowConfigurator` bridge remains only for represented URL/dirty state,
key-window notification, and close veto while a recording or asynchronous save
is active. `SplitViewAutosaveConfigurator` remains because SwiftUI has no
equivalent divider-position persistence with the collapsed-rail invariant.

`ActiveDocumentRegistry` lets App Intents resolve the currently active editor
without retaining a process-global model. It captures a stable token per
registered editor, serializes actions, returns a typed no-active-document error
before any scene registers (including cold launch), and never retargets a queued
action after its original editor closes. The present app shell still creates one
editor model; the registry is deliberately ready for a future multi-document
implementation without claiming that feature today.

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
