# Technical Constraints

## Platform & toolchain

- **Target**: macOS 27 (`MACOSX_DEPLOYMENT_TARGET = 27.0`). `SUPPORTED_PLATFORMS = macosx` — this is a Mac-only app so AppKit interop is fair game.
- **Language**: Swift 6 mode features enabled (approachable concurrency). `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — types are main-actor isolated unless marked otherwise. Push blocking media work off the main actor deliberately.
- **UI**: SwiftUI with the **Observation** framework (`@Observable`, `@Bindable`). No Combine — prefer `async`/`await` and `AsyncSequence`.
- **Xcode project**: target `MyApp`, product/app name **LocalCut Studio**. Build/run via the `xcode-tools` MCP (`BuildProject`, `RunProject`) or `xcodebuild`.

## Frameworks

- **AVFoundation** — `AVURLAsset`, `AVMutableComposition`, `AVMutableVideoComposition`, `AVPlayer`, `AVAssetExportSession`, `AVAssetWriter`, `AVAssetImageGenerator`. Use the modern `async` load APIs (`load(.duration)`, `loadTracks(withMediaType:)`).
- **AVKit** — `AVPlayerView` for the preview surface (wrapped in `NSViewRepresentable`).
- **Core Image / Metal** — effect chain and custom `AVVideoCompositing` (later phases).
- **CoreMedia** — `CMTime`/`CMTimeRange` for all timeline math. A timescale of `600` is the default for constructed times.
- **UniformTypeIdentifiers** — `UTType` for import/export type filtering.

## Sandbox & entitlements

- App Sandbox is **ON** (`ENABLE_APP_SANDBOX = YES`).
- `ENABLE_USER_SELECTED_FILES = readwrite` — read imported media and write exports to user-chosen locations only.
- Imported files use **security-scoped** access (`startAccessingSecurityScopedResource`), retained for the session; persisted via bookmarks once the project document lands.
- Do **not** add entitlements speculatively. Add one only when a concrete API fails without it.

## Constraints / rules

- **No third-party media libraries** — AVFoundation/VideoToolbox/Core Image cover the pipeline. Avoid adding SPM deps without a spec.
- **Time math in `CMTime`** — never convert to `Double` seconds for editing decisions except at the UI boundary (pixels ↔ seconds).
- **Async asset loading** — never use the deprecated synchronous `AVAsset` accessors; they block and are removed in modern SDKs.
- **One `AVPlayer`** — owned by `EditorModel`; views observe it, never create their own.
