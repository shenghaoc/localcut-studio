# Tasks: Design-System Integration Polish

> Status: **Implemented**. Presentation-led, with narrow computed model helpers;
> see [design](./design.md) and [requirements](./requirements.md).

## Shared header

- [x] **T1.1** Add `EditorPanelHeader` (title + `@ViewBuilder` trailing slot,
  12 pt horizontal + `verticalPadding` defaulting to 8, no baked-in `Divider`)
  with the title carrying `.isHeader`; Timeline passes `verticalPadding: 6`
  (R1.1, R1.2).
- [x] **T1.2** Add the `Trailing == EmptyView` convenience init (R1.3).
- [x] **T1.3** Route `MediaBinView` and `TimelineView` headers through
  `EditorPanelHeader`, each keeping its own separator; use the Inspector side
  rail's segmented pane switcher as its single visible and VoiceOver heading
  (R1.4).

## Timeline chrome

- [x] **T2.1** Collapse the timeline header to title + zoom slider in the
  trailing slot (R2.1).
- [x] **T2.2** Add the `PlayheadHead` triangle shape and draw it at the
  ruler/lane boundary inside `PlayheadView`, alongside the scrub line, passing
  `rulerHeight` through; the head is the direct-manipulation grab target while
  the ruler remains the assistive scrub target (R2.2, R2.3).

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

- [x] **T7.1** Add `Theme.swift` with system-semantic `Color.lcAccent`,
  `Color.lcLane`, and `Color.lcRail` tokens.
- [x] **T7.2** Let the `EditorView` root inherit the user's macOS appearance and
  control accent; keep the preview canvas black as a content surface.
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
  Add Marker (M); View ▸ Show Inspector (⌥⌘I) / Go to Start (⌘↑). Delete has no
  bare menu/toolbar key equivalent; clips/transitions use the timeline-scoped
  `onDeleteCommand` so text editing keeps Backspace; clip blocks and transition
  glyphs are focusable so either selection can receive that command. Spacebar
  play/pause is handled by the window-scoped `EditorKeyHandler` local monitor (in
  `TimelineView.swift`) rather than a menu key-equivalent — a bare `.space` menu
  shortcut is global in AppKit and would swallow spaces typed into text inputs.
  The monitor also exempts focused non-text first responders (NSControl +
  SwiftUI-hosted controls) so a Tab-focused checkbox/button receives Space
  normally. Remove dead `exportTapped()`.
- [x] **T9.2** Lift `isSideRailCollapsed` → `EditorModel.inspectorVisible`
  (UserDefaults-persisted); update toolbar, layout, collapsed-rail, and menu.
- [x] **T9.3** Honor Reduce Motion on the scopes transition/animation; adaptive
  marker stroke (`separatorColor`); clip-kind glyph; format-badge VoiceOver
  label; scopes `accessibilityValue`; secondary tool picker `.isHeader`.
- [x] **T9.4** Standard controls/materials: status bar `.bar`; Preserve Pitch +
  Beauty toggles → checkbox; inspector timecodes `monospacedDigit`; render-queue
  inline `Text` placeholder; Master Gain via `LabeledSliderRow`; scopes on
  `lcLane`; timeline/scopes fonts → text styles, with the top waveform label
  anchored below its line for Dynamic Type; Align-Window reset.
- [x] **T9.5** Pointer feedback: ruler resize cursor + scrub tooltip; marker
  pointing-hand cursor; ruler VoiceOver label/value + adjustable scrub action.
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
  clip + stroke with `.glassEffect(in: .rect(cornerRadius:))`; keep an explicit
  max width so the overlay stays compact; remove the dead `VisualEffectBackground`.
  (HIG: Liquid Glass on the functional/floating layer only, sparingly — system
  toolbars already adopt it automatically.)
- [x] **T10.3** De-hardcode `Theme.swift`: delegate `lcAccent` to the user's
  system accent; back `lcLane` with `.underPageBackgroundColor` and
  `lcRail` with `.windowBackgroundColor` (semantic, appearance-adaptive) instead
  of raw RGB literals.
- [x] **T10.4** Unify selection accents: point the custom-drawing
  `Color.accentColor` sites at `Color.lcAccent` so *bespoke* affordances
  (timeline clip / transition / marker diamond, render-queue badge, diagnostics
  sparkline) match the user's system accent. Standard list-row selection (media
  bin, markers inspector) intentionally stays on the native system selection
  colour per **T9.6**.
- [x] **T10.5** Remove the app-specific AccentColor asset and global accent
  build setting so native controls, focus rings, and bespoke selection all
  follow the user's macOS control accent.
- [x] **T10.6** Codex review follow-up: keep the scrub ruler reachable to
  VoiceOver instead of marking it decorative, and keep the clip context-menu
  Split command enabled for unselected clips because the command selects the
  clicked clip before splitting.
- [x] **T10.7** Live review follow-up: remove global bare-Delete key equivalents
  from menu/toolbar actions; keep countdown text white over its dark overlay;
  constrain the Diagnostics HUD width; verify the callout list keeps `.isSelected` for
  VoiceOver; replace `.yellow` warning indicators with `.orange` for
  accessibility contrast; normalise status-message ellipsis from ASCII `...` to
  Unicode `…`; add semantic timeline colour tokens (`lcCaptionFill`,
  `lcCaptionStroke`, `lcTransitionFill`, `lcTransitionIcon`, `lcBeatMarker`,
  `lcTrimHover`) to `Theme.swift`; make transition glyphs focusable and expose
  selected state so timeline-scoped Delete and VoiceOver work after selection.

## Final pre-merge review hardening

- [x] **T11.1** Harden the affected picker, import, document, preview, capture,
  detection, and interchange failures with underlying detail plus one
  punctuation-safe recovery suggestion; ignore intentional cancellation
  without swallowing real failures, bound batch announcements, and keep the
  full truncated status available through help and accessibility (R7.1).
- [x] **T11.2** Give speed, look, and skin keyframe navigation model-derived
  neighbour availability using the seek tolerance; explain disabled shared-nav
  controls through help and accessibility hints (R7.2).
- [x] **T11.3** Flatten Project and Overlay grouped-Form content so collapsible
  sections do not contain nested sections or duplicate headings (R7.3).
- [x] **T11.4** Add an adaptive vertical fallback for scaled caption timing
  controls in the narrow inspector (R7.4).
- [x] **T11.5** Reconcile system appearance/high-contrast behavior, functional
  HUD glass, badge recipes, and shipping design primitives across `PRODUCT.md`,
  `DESIGN.md`, and `Theme.swift` (R7.5).
- [x] **T11.6** Use “Delete Transition” consistently in the menu, inspector,
  undo action, and success status (R7.6).
- [x] **T11.7** Disambiguate the recorder microphone toggle from its adjacent
  “Input Device” picker for visual and VoiceOver users (R7.7).

## Verification

- [x] **T6.1** `xcodebuild test` (Debug, macOS) compiles the app without new
  source diagnostics and the full suite passes with no count regression
  (R6.1, R6.2).
- [x] **T6.3** Add focused pure tests for ruler adjustment step limits, project
  boundary clamping, and the empty-project case (R2.3, R6.2).
- [x] **T6.4** Stabilize the recorder UI flow test by activating its identified
  buttons directly instead of relying on window-level synthetic key delivery,
  and re-activate the app before each click so an unrelated foreground window
  cannot intercept the action; keep every recorder-state and gap-collapse
  assertion unchanged.
- [x] **T6.2** Confirm no stored model field/schema/composition-math change and
  that the standalone `app/` prototype is not merged (R6.3).
