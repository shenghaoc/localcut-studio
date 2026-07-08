# Design: Design-System Integration Polish

> Status: **Implemented**. Pure view-layer polish; no engine, model, or
> composition-math changes.

## Goal

The LocalCut Studio Design System handoff shipped a standalone SwiftUI
prototype (`app/`) recreating the editor shell. Rather than import the
prototype wholesale, this spec lifts the **production-safe presentation
details** out of that handoff and folds them into the real app's views so the
shipping editor matches the design reference while keeping repo-native
behaviour (real `AVPlayer` preview, `LocalCutCore` timecode, undo, persistence).

Scope is deliberately narrow: shared chrome, timeline playhead affordance,
inspector media imagery, render-preset metadata, and VoiceOver labelling.
Nothing here touches `CMTime` math, the compositor, or the document schema.

## Surfaces

### Shared panel header — `EditorPanelHeader`

A reusable header view matching the design-system `PanelHeader`: a `.headline`
title carrying the `.isHeader` accessibility trait, an optional trailing
`@ViewBuilder` slot for pane controls, and 12 pt horizontal padding. Vertical
padding is a parameter defaulting to 8 (Inspector, Media); the Timeline passes
6 to preserve its exact gutter/ruler alignment, which the old hand-rolled header
used. The view draws no `Divider` — call sites (`InspectorView`,
`MediaBinView`, `TimelineView`) own their own separators so the header composes
with adjacent controls. An `EmptyView` trailing convenience init covers headers
with no actions.

The Media bin and Timeline panes use `EditorPanelHeader` directly. The side rail
instead switches panes with a segmented control (Inspector / Audio / Captions /
Tools); that switcher carries `.accessibilityAddTraits(.isHeader)` and an
`accessibilityValue` of the active pane, so it stands in for a per-pane header in
the VoiceOver rotor's Headings list without a title that would duplicate the tab.

### Timeline chrome

- The timeline header collapses to the design-system shape: a compact title and,
  in the trailing slot, page-left / center-playhead / page-right scroll buttons
  + the zoom slider (no summary line). Page-scroll math reads the live viewport
  leading-edge via `onScrollGeometryChange`, so it pages from where the user
  actually is even after a manual trackpad/scrollbar scroll. The scroll
  viewport also carries an `accessibilityAdjustableAction` so VoiceOver rotor
  "Adjust value" performs the same page-left/right action.
- `PlayheadHead` — a small downward triangle pinned to the ruler/lane boundary,
  centred on the scrub `x`. The precise 1.5 pt red line still spans the full
  height; the head is the design-system grab affordance and is **interactive**
  (its `DragGesture` does a tolerant seek while dragging, precise on end). The
  scrub line itself stays `allowsHitTesting(false)` so clicks fall through to
  clips and the ruler. Both live in the isolated `PlayheadView` so they
  re-evaluate per `currentTime` tick without invalidating the rest of the
  timeline. The head carries `accessibilityHidden(true)` because assistive
  scrubbing lives on the ruler Canvas, which exposes a timeline-scrub label,
  live playhead value, hint, and adjustable action.

### Inspector media imagery — `InspectorPosterView`

The clip and media inspector sections lead with a poster: the media thumbnail
filling a rounded `.quaternary` plate, or an SF Symbol (`film` / `waveform`)
fallback when no thumbnail exists. Decorative only (`accessibilityHidden`); the
adjacent labelled rows carry the readable metadata.

### Render-queue preset metadata

`presetSubtitle` is enriched from `codec • size • aspect` to
`container • codec • size • aspect • bitrate`, with the raw codec string
upper-cased for unknown codecs. The subtitle is `lineLimit(1)` +
`.truncationMode(.tail)` so the five segments don't wrap in a narrow inspector.
The job's output name truncates in the middle (`lineLimit(1)` +
`.truncationMode(.middle)`) so long paths stay on one line.

## Accessibility

The integration also closes the VoiceOver gaps the design pass surfaced:

- Containers that carry a custom label use `.accessibilityElement(children:
  .ignore)` (media bin rows, preview, timeline track/caption gutter rows) so the
  custom label is read once instead of stacking with child labels.
- Track and caption-track gutter labels are built with
  `AttributedString(localized: "^[\(count) clip](inflect: true)")` so plural
  agreement and localization come from Foundation rather than manual
  `count == 1 ? …` logic.
- The preview exposes a localized `accessibilityValue` describing the empty vs.
  active state; the transport time reads "Playhead m:ss.ff of m:ss.ff".
- The timeline ruler stays reachable to VoiceOver as the direct scrub target:
  it reports the current playhead time, supports adjustable increment/decrement
  scrubbing, and leaves only decorative tick/marker label drawing hidden.

## Visual identity pass

A screen-recording review found the editor read as a default light-grey SwiftUI
app floating small on the desktop — no identity, and footage-unfriendly. This
pass gives it a deliberate dark "studio" look without touching any engine code,
all driven from a tiny `Theme.swift` token set:

- **Dark editor chrome.** `EditorView` applies `.preferredColorScheme(.dark)` so
  the whole window is dark — the convention for video tools, so footage and
  posters pop instead of fighting a bright shell.
- **One brand accent.** `Color.lcAccent` is a warm film-gold applied via
  `.tint` on the editor root, so the active side-rail tab, primary buttons,
  steppers, and toggles share one identity colour that is deliberately *not*
  the blue/teal every other NLE defaults to. The red scrub playhead stays red.
- **A timeline that reads as a surface.** Video/audio/caption lanes fill with
  `Color.lcLane` (a hair lighter than the window) so empty tracks look like
  tracks, not a void; the gutter/ruler sit on `Color.lcRail`.
- **A comfortable default window.** `WindowConfigurator` sizes the editor to a
  1360×860 canvas centred on the active screen on first launch only (one-shot
  `UserDefaults` guard, deferred one runloop tick so it survives SwiftUI's
  initial-layout sizing). Later launches keep whatever size the user left.
- **Quieter Media chrome.** The "Copy imports into bundle" toggle moves from
  above the library to a small caption-weight footer — it is a save-time
  preference, not a primary action — and the empty state reads "No media yet"
  with a `film.stack` glyph.
- **Side-rail label.** The segmented panel switcher takes `.labelsHidden()` so
  the redundant "Side panel" text no longer hyphenates into "Side / pan- / el".
- **Collapsible side rail.** A scene-persisted hide/show control mirrors the
  browser editor's collapsible right rail while staying native: the expanded
  rail keeps its segmented tabs, the collapsed state becomes a slim restore
  strip, and the toolbar exposes the same action for keyboard/pointer workflows.

## Non-goals

Real AVFoundation playback/export, trim/drag, and the inspector feature
surfaces already exist in the app and are untouched. The standalone `app/`
prototype is **not** merged. No new model fields, no schema bump, no test-count
regression. The accent and dark scheme are presentation-only (`.tint` /
`.preferredColorScheme`); they introduce no custom-drawn control styles.

## HIG conformance pass

A 10-dimension audit against Apple's Human Interface Guidelines (Design
Principles + Designing for macOS), each finding adversarially verified against
the source, drove this pass. The dominant theme was **menu-bar completeness**:
primary commands existed only on the toolbar or as bare key handlers. Changes
are all standard SwiftUI/AppKit (no new paradigms):

- **Menu bar mirrors the toolbar.** `EditorModel.requestImport()` /
  `requestExport()` back new **File ▸ Import… (⌘I)** and **File ▸ Export…
  (⇧⌘E)**; **Edit ▸ Delete Selected Clip** and **Edit ▸ Add Marker (M)** mirror
  the timeline; **View ▸ Show Inspector (⌥⌘I)** and **Go to Start (⌘↑)** join
  Show Diagnostics. The **Space** shortcut for play/pause is intentionally not
  a menu key-equivalent (those fire globally, swallowing spaces typed into text
  fields) — it lives on a window-scoped `NSEvent` local monitor
  (`EditorKeyHandler` in `TimelineView.swift`) that yields to focused text
  inputs *and* any focused non-text control (so a Tab-focused checkbox /
  button receives Space normally).
- **Single source of truth for the inspector.** `isSideRailCollapsed`
  (`@SceneStorage`) is lifted to `EditorModel.inspectorVisible` (UserDefaults-
  persisted) so the menu toggle, toolbar button, and collapsed-rail restore
  strip can't disagree.
- **Appearance & accessibility settings honored** (orthogonal to the deliberate
  forced-dark chrome): Reduce Motion gates the scopes-panel transition/animation;
  the marker stroke uses the adaptive `separatorColor`; clip blocks gain a
  film/waveform glyph so kind isn't hue-only (Differentiate Without Color); the
  format badge gets a spelled-out VoiceOver label; the scopes Canvas gains a
  live/empty accessibility value.
- **Standard controls & materials.** The status bar uses `.bar`; the Beauty
  toggles drop `.switch` for the Form-default checkbox; inspector timecodes use
  `monospacedDigit`; the render-queue empty state uses inline `Text` with `.foregroundStyle(.secondary)`;
  Master Gain uses the shared `LabeledSliderRow`; the scopes pane sits on the
  recessed content surface (`lcLane`) rather than a chrome material; timeline
  fonts use `caption2`/monospaced text styles instead of raw point sizes.
- **Pointer feedback.** The ruler shows a resize cursor + "Drag to scrub"
  tooltip; marker diamonds show the pointing-hand cursor (the trim handles
  already used `resizeLeftRight`, matching the macOS 27 pointer set).
- **List selection unified** on the system selection colour across the media bin
  and marker rows (honoring the user's system accent for standard list rows
  while the bespoke timeline keeps the brand gold).

### HIG tensions (deliberate product choices, kept)

- **Forced dark mode** overrides the user's Appearance, which strict HIG
  discourages — but a fixed low-luminance UI is the near-universal pro-NLE
  convention (Final Cut, Premiere, Resolve, Logic) so colour judgement isn't
  biased by surrounding chrome. Kept; the orthogonal accessibility settings
  above are honored instead.
- **Brand accent** vs the user's system accent: kept for bespoke timeline /
  transition / marker / render affordances that have no system-control
  equivalent, while standard list-row selection uses the system colour.

### Keyboard & direct-manipulation follow-ups (now complete)

The medium-risk interaction items are done and manually verified with real media:

- **Split-view divider autosave** — `SplitViewAutosaveConfigurator` walks to the
  enclosing `NSSplitView` and sets `autosaveName`, so media-bin / inspector /
  timeline divider positions persist across launches.
- **Media-bin arrow-key navigation** — focusable rows (`@FocusState`) with
  `onMoveCommand` / `onDeleteCommand` and a focus ring; timeline clips are
  likewise focusable with arrow-key movement that scrolls the focused clip into
  view, plus Page-Left/Right and center-playhead buttons and an
  accessibility-adjustable timeline viewport.
- **Long-clip identity** — `ClipIdentityOverlay` repeats the clip's glyph + name
  across a long body so the tail of a clip isn't an unlabeled slab.
- **Draggable playhead head** — the head is a grab target at the ruler/lane
  boundary that scrubs by drag translation (origin-independent); the scrub line
  stays non-interactive so clicks still fall through to clips and the ruler,
  and the ruler Canvas remains the VoiceOver-adjustable scrub target.
- **Clip-body move cursor** — declarative `.pointerStyle(.grabIdle/.grabActive)`
  on the clip body: region-based, so there's no `NSCursor` stack to unbalance,
  and it coexists with the trim handles' resize cursor.

## Liquid Glass + colour-token de-hardcode

macOS 26's Liquid Glass is adopted **only on the functional, floating layer**,
per Apple's HIG ("don't use Liquid Glass in the content layer; use it
sparingly"). Standard toolbars/sidebars already pick it up automatically, so the
custom additions are limited to the two genuinely-floating controls:

- **Preview transport** floats over the video as an interactive
  `.glassEffect(.regular.interactive())` capsule (the canonical
  controls-over-media case) instead of an opaque `.bar` strip; the
  render-format readout stays a `.thinMaterial` badge, because a non-interactive
  label is content, not a control.
- **Diagnostics HUD** uses `.glassEffect(in: .rect(cornerRadius:))`, replacing a
  hand-rolled `NSVisualEffectView` + clip + stroke.

The same pass removes hard-coded colour literals (the project's own UI standards
forbid colours that fight the system appearance):

- The **brand accent** moves from a Swift `Color(red:…)` literal to an
  `Assets.xcassets` `AccentColor` set (Display-P3, with room for light/dark and
  high-contrast variants). `lcLane`/`lcRail` become semantic system colours
  (`.underPageBackgroundColor` / `.windowBackgroundColor`) that adapt with the
  appearance instead of pinning a fixed grey.
- **Selection** is unified to the brand gold on bespoke affordances: the
  `Color.accentColor` references in custom timeline / marker-diamond /
  render-queue / diagnostics drawing now read `Color.lcAccent`, so selection
  matches the tinted controls instead of falling back to system blue — while
  standard list-row selection keeps the system colour (see *HIG tensions*). The
  target now sets *Global Accent Color Name* = `AccentColor` (**T10.5**), so
  `Color.accentColor` resolves to the gold app-wide (system focus rings
  included); the explicit `lcAccent` references are therefore equivalent and
  could later be simplified back to `Color.accentColor`.
