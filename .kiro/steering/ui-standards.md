# UI Standards

## Aesthetic

Native, professional-tool macOS look in the spirit of TeXShop. Lean on system materials, the user's macOS control accent, and standard controls; do not reskin macOS into a web app. Follow the system light/dark appearance instead of forcing one, and do not introduce a branded gold or amber palette. The editor is a single window with a three-pane workspace (media bin · preview · inspector) above a full-width timeline, split with `HSplitView` / `VSplitView`.

## Layout

- **Workspace**: `VSplitView { HSplitView { MediaBin | Preview | Inspector } ; Timeline }`. Panes have sensible `minWidth`/`idealWidth`; the preview gets `layoutPriority`.
- **Preview**: black letterbox background; native `AVPlayerView` (controls driven by our transport bar, not AVKit's, so the timeline playhead stays authoritative).
- **Timeline**: bespoke. Left gutter with track labels; horizontally scrollable content with a Canvas ruler, one lane per track, rounded clip blocks, and a red playhead. `pixelsPerSecond` is the zoom unit.
- **Inspector**: `Form { .formStyle(.grouped) }` — contextual clip/media sections plus project render settings.

## Interaction

- **Selection** drives the inspector. Single click selects; double-click (bin) adds to timeline; context menus offer the same actions.
- **Transport**: Space = play/pause; click/drag the ruler to scrub. Keep the playhead and `AVPlayer` time in sync via the periodic time observer.
- **Toolbar** = frequent actions (Split, Delete, Export) with SF Symbols + labels; the menu bar carries the full taxonomy.
- **Status**: a single status line communicates background work (import, export) and errors. Long operations show determinate progress.

## Visual tokens

- Use SF Symbols for all iconography; every icon-only control has a `.help(...)` tooltip and an accessibility label.
- Track colours: video = blue family, audio = green family, selection = the user's system accent. Orange is reserved for genuine warnings or paused/transient states, never branding.
- Respect light/dark automatically; never hard-code colours that fight the system appearance.

## Consistency rules

- One label per concept across toolbar, menu, and context menu.
- Disable (don't hide) actions that are temporarily unavailable, and explain why via `.help`.
- New panels follow the same header (title + trailing actions) + `Divider` + content pattern as `MediaBinView`/`InspectorView`.
