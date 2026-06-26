# Tasks: Design-System Integration Polish

> Status: **Implemented**. View-layer only; see [design](./design.md) and
> [requirements](./requirements.md).

## Shared header

- [x] **T1.1** Add `EditorPanelHeader` (title + `@ViewBuilder` trailing slot,
  12 pt horizontal + `verticalPadding` defaulting to 8, no baked-in `Divider`)
  with the title carrying `.isHeader`; Timeline passes `verticalPadding: 6`
  (R1.1, R1.2).
- [x] **T1.2** Add the `Trailing == EmptyView` convenience init (R1.3).
- [x] **T1.3** Route `InspectorView`, `MediaBinView`, and `TimelineView`
  headers through `EditorPanelHeader`, each keeping its own separator (R1.4).

## Timeline chrome

- [x] **T2.1** Collapse the timeline header to title + zoom slider in the
  trailing slot (R2.1).
- [x] **T2.2** Add the `PlayheadHead` triangle shape and draw it at the
  ruler/lane boundary inside `PlayheadView`, alongside the scrub line, passing
  `rulerHeight` through; non-interactive (R2.2, R2.3).

## Inspector imagery

- [x] **T3.1** Add `InspectorPosterView` (thumbnail or SF Symbol fallback on a
  `.quaternary` plate, `accessibilityHidden`) (R3.1–R3.3).
- [x] **T3.2** Lead the Clip and Media inspector sections with the poster.

## Render-queue metadata

- [x] **T4.1** Enrich `presetSubtitle` to
  `container • codec • size • aspect • bitrate`; upper-case unknown codecs (R4.1).
- [x] **T4.2** Single-line, tail-truncated preset subtitle (R4.2).
- [x] **T4.3** Single-line, middle-truncated job output name (R4.3).

## Accessibility

- [x] **T5.1** Switch custom-labelled containers from `.combine`/`.contain` to
  `children: .ignore` (media-bin rows, preview, timeline track/caption rows)
  (R5.1).
- [x] **T5.2** Build track/caption labels with `AttributedString(localized:)` +
  `inflect: true` for plural agreement; muted caption tracks use a full
  localized variant rather than an appended `, muted` (R5.2).
- [x] **T5.3** Add the preview's localized `accessibilityValue` and the
  transport "Playhead … of …" label (R5.3).

## Visual identity pass

- [x] **T7.1** Add `Theme.swift` with `Color.lcAccent` (film-gold), `Color.lcLane`,
  and `Color.lcRail`.
- [x] **T7.2** Apply `.preferredColorScheme(.dark)` and `.tint(.lcAccent)` to the
  `EditorView` root.
- [x] **T7.3** Fill timeline video/audio/caption lanes with `Color.lcLane` so empty
  tracks read as surfaces.
- [x] **T7.4** `WindowConfigurator` sizes the editor to 1360×860 centred on first
  launch only (one-shot `UserDefaults` guard, deferred one runloop tick); add
  `.defaultSize` as a fallback.
- [x] **T7.5** Move the "Copy imports into bundle" toggle to a caption-weight
  footer; empty state reads "No media yet" with `film.stack`.
- [x] **T7.6** `.labelsHidden()` on the side-rail segmented switchers so the
  "Side panel"/"Project tool" labels stop hyphenating.
- [x] **T7.7** Add a scene-persisted side-rail collapse control, slim restore
  rail, and matching toolbar toggle so the preview/timeline can reclaim width
  when the inspector is not needed.

## Review hardening (codex/gemini, post-visual-pass)

- [x] **T8.1** Restore the `Color.lcRail` token and apply it to the timeline
  gutter and ruler so the rail reads as a band above the lanes (the de-hardcode
  refactor had dropped it).
- [x] **T8.2** Rebuild the track/caption accessibility labels as whole localized
  strings (one per kind / muted state) so translators control the full order.
- [x] **T8.3** Apply `.accessibilityElement(children: .ignore)` to the preview
  canvas *before* its overlays so the transport controls stay separate,
  individually reachable elements.
- [x] **T8.4** Give the side-rail segmented switcher `.isHeader` so rotor users
  reach a pane heading after the per-pane `EditorPanelHeader` was dropped.
- [x] **T8.5** Guard `WindowConfigurator.applyInitialFrameIfNeeded` with an
  in-memory flag so repeated `attach(to:)` calls don't enqueue the deferred
  frame block more than once.

## HIG conformance pass (Design Principles + Designing for macOS)

- [x] **T9.1** Menu-bar completeness: `requestImport()`/`requestExport()` on the
  model; File ▸ Import… (⌘I) / Export… (⇧⌘E); Edit ▸ Delete Selected Clip /
  Add Marker (M); View ▸ Show Inspector (⌥⌘I) / Play (Space) / Go to Start (⌘↑);
  spacebar owned solely by the Play command. Remove dead `exportTapped()`.
- [x] **T9.2** Lift `isSideRailCollapsed` → `EditorModel.inspectorVisible`
  (UserDefaults-persisted); update toolbar, layout, collapsed-rail, and menu.
- [x] **T9.3** Honor Reduce Motion on the scopes transition/animation; adaptive
  marker stroke (`separatorColor`); clip-kind glyph; format-badge VoiceOver
  label; scopes `accessibilityValue`; secondary tool picker `.isHeader`.
- [x] **T9.4** Standard controls/materials: status bar `.bar`; Beauty toggles →
  checkbox; inspector timecodes `monospacedDigit`; render-queue
  `ContentUnavailableView`; Master Gain via `LabeledSliderRow`; scopes on
  `lcLane`; timeline fonts → text styles; Align-Window reset.
- [x] **T9.5** Pointer feedback: ruler resize cursor + scrub tooltip; marker
  pointing-hand cursor.
- [x] **T9.6** Unify list-row selection on the system selection colour (media
  bin + markers).
- [x] **T9.7** Formerly-deferred interaction work, now complete:
  - Split-view divider autosave (`SplitViewAutosaveConfigurator`) and media-bin
    arrow-key navigation (`@FocusState` + `onMoveCommand`) — landed in `f4a6cd7`
    alongside timeline clip keyboard nav, page-scroll buttons, and repeated
    long-clip identity labels.
  - Draggable playhead head — the head is a grab target at the ruler/lane
    boundary that scrubs by drag translation; the scrub line stays
    non-interactive (`PlayheadView`).
  - Clip-body move cursor — declarative `.pointerStyle(.grabIdle/.grabActive)` on
    the clip body (region-based, no `NSCursor` stack to unbalance; coexists with
    the trim handles' resize cursor).

## Liquid Glass + colour-token de-hardcode

- [x] **T10.1** Float the preview transport as an interactive Liquid Glass
  capsule over the video (`.glassEffect(.regular.interactive())`) instead of a
  `.bar` strip; the render-format readout is a `.thinMaterial` badge — a
  non-interactive label belongs to the content layer, not glass.
- [x] **T10.2** Replace the Diagnostics HUD's hand-rolled `NSVisualEffectView` +
  clip + stroke with `.glassEffect(in: .rect(cornerRadius:))`; remove the dead
  `VisualEffectBackground`. (HIG: Liquid Glass on the functional/floating layer
  only, sparingly — system toolbars already adopt it automatically.)
- [x] **T10.3** De-hardcode `Theme.swift`: move the brand accent to
  `Assets.xcassets` as `AccentColor` (Display-P3, room for light/dark +
  high-contrast variants); back `lcLane` with `.underPageBackgroundColor` and
  `lcRail` with `.windowBackgroundColor` (semantic, appearance-adaptive) instead
  of raw RGB literals.
- [x] **T10.4** Unify selection accents: point the custom-drawing
  `Color.accentColor` sites at `Color.lcAccent` so *bespoke* affordances
  (timeline clip / transition / marker diamond, render-queue badge, diagnostics
  sparkline) read brand-gold rather than system blue. Standard list-row
  selection (media bin, markers inspector) intentionally stays on the system
  selection colour per **T9.6**.
- [ ] **T10.5** (delegated — project-file change) Set the app target's
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor` so
  `Color.accentColor` and system focus rings inherit the gold app-wide; the
  explicit `lcAccent` references in T10.4 then become equivalent.

## Verification

- [x] **T6.1** `xcodebuild test` (Debug, macOS) compiles with zero warnings and
  the full suite passes with no count regression (R6.1, R6.2).
- [x] **T6.2** Confirm no model/schema/composition change and that the
  standalone `app/` prototype is not merged (R6.3).
