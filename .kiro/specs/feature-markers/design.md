# Design: Timeline Markers (P10 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 34 (beat-tools) and Phase 44 (tutorial finishing).

## Goal

Give the project model a first-class collection of **timeline markers**: named
points in time the editor draws on the ruler and exposes through keyboard
shortcuts, an inspector list, and the undo stack. Markers are the substrate
Phase 34 writes onto when it auto-detects musical beats, and what Phase 44 uses
to drive chapter export. This spec is the data + UI layer only — the
auto-population from beat detection lives in [`phase-34-beat-tools`](../phase-34-beat-tools/),
and chapter rendering lives in [`phase-44-tutorial-finishing`](../phase-44-tutorial-finishing/).

## Model

```swift
struct TimelineMarker: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var time: CMTime
    var name: String
    var colour: RGBAColour?    // nil ⇒ track-default accent (drawn yellow)
}
```

`time` is in project-timeline space (not source space). `name` is a short
user-facing label drawn above the glyph and read by VoiceOver. `colour` is
optional so Phase 34 can paint beat-derived markers a distinct hue without
forcing every hand-placed marker to carry one. `RGBAColour` is the type already
added in PR #10 (`Models.swift`) for caption fills — reusing it keeps marker
colours and caption colours on one Codable path.

The `Project` gains:

```swift
var markers: [TimelineMarker] = []
```

The array is kept sorted by `time`. Insertion paths preserve this invariant, so
draw + lookup code can treat it as ordered without re-sorting per frame.

`Project.duration` is unchanged: a marker past the last clip is allowed (and
draws into the ruler's trailing headroom), but it does not extend playable
duration the way a caption tail does — markers are annotations, not content.

## Persistence

`ProjectDocument` grows a `markers: [TimelineMarker]` field. The struct itself
is Codable (no nested `CMTime` workaround needed — same `CMTimeCode` rational
treatment as caption lines/keyframes, via an explicit `init(from:)` /
`encode(to:)`). Lenient decoding (missing field → empty) keeps PR #10-era
documents openable. `currentSchemaVersion` bumps from 2 to 3; the existing
newer-schema guard in `EditorModel.load(document:from:)` already covers cross-
version safety so a build that predates this spec opening a v3 document still
falls back to "saved in a newer format — saving downconverts".

Undo/redo extends `ProjectState` with a `markers: [TimelineMarker]` slice,
captured in `captureState` and restored in `applyState`, the same way caption
tracks were added in PR #10.

## UI

### Ruler glyphs

`TimelineView.swift`'s ruler `Canvas` gains a marker pass after the tick pass.
Each marker draws as:

- A 10×10 filled diamond (or `Path`-stroked downward chevron) centred on
  `time * pps`, anchored to the ruler's baseline.
- The marker's `name` rendered at 9pt above the glyph, clipped to the half-step
  between this marker and its neighbours so adjacent labels never overlap.
- Filled with `marker.colour?.cgColor` if set, otherwise the system accent /
  yellow fallback.

A marker is **selected** when `model.selectedMarkerID == marker.id`; selected
markers draw with a 2pt accent-coloured stroke around the glyph. Tapping a
marker selects it; tapping the ruler away from any glyph clears the selection.

### Keyboard

A new `MarkerKeyHandler` view modifier installs an `NSEvent`
`addLocalMonitorForEvents(matching: .keyDown)` on `TimelineView`. The monitor
is scoped two ways to avoid hijacking unrelated keys:

1. **Window identity** — only events whose `event.window` is the same window
   the timeline view is hosted in are considered, so multi-project windows
   don't fight over each other's shortcuts.
2. **Text-input first responder defer** — if the window's first responder is
   an `NSText` / `NSTextField` / `NSTextView`, the event passes through
   unchanged so caption / inspector typing isn't stolen.

| Key             | Action                                                       |
|-----------------|--------------------------------------------------------------|
| `M`             | Add a marker at the playhead's current time.                 |
| `Shift+M`       | Open a rename popover anchored to the selected marker, or report concise status guidance when no marker is selected. |
| `Delete`        | Remove the selected marker (only when one is selected — does not steal the existing clip/transition delete shortcut). |

Shift+M's rename popover is a small `TextField` + Done button anchored over
the selected marker glyph. Submitting commits a `Rename Marker` undo step. If
no marker is selected, the handler leaves selection unchanged and sets
`statusMessage` so the editor's live status line tells the user to select a
marker on the ruler to rename instead of silently no-oping.

### Inspector panel

`InspectorView` grows a `MarkersInspectorView` section that mirrors
`CaptionsInspectorView`'s shape:

- A header row with an "Add at Playhead" button.
- A scrollable list, one row per marker, sorted by `time`. Each row shows:
  - A click-to-seek timecode chip (sets `model.currentTime` and `seek(toSeconds:)`).
  - A name `TextField` bound through `updateMarkerCoalesced` so a typing burst
    folds into one undo step.
  - A delete icon button.

The inspector list is purely a navigation surface — the timeline ruler is the
canonical view of marker placement.

### Selection exclusivity

Every marker-selection path (ruler tap, inspector row tap, seek button, `M`
keyboard) funnels through `selectMarker(id:)` on `EditorModel`. This single
function sets `selectedMarkerID` **and** clears `selectedClipID`,
`selectedTransitionClipID`, and `selectedMediaID`, maintaining the mutual-
exclusivity invariant that the rest of the codebase relies on (only one kind of
object is "selected" at a time). The inspector's timecode chip button calls
`seekToMarker(id:)` which also invokes `selectMarker` internally.

## Editor commands

A `EditorModel+Markers.swift` extension follows the
`EditorModel+Captions.swift` pattern exactly:

```swift
extension EditorModel {
    func addMarkerAtPlayhead()
    func removeMarker(id: TimelineMarker.ID)
    func renameMarker(id: TimelineMarker.ID, to name: String)
    func updateMarkerCoalesced(id: TimelineMarker.ID,
                               name: String? = nil,
                               colour: RGBAColour? = nil)
}
```

`addMarkerAtPlayhead`, `removeMarker`, `renameMarker` route through
`performUndoable`. `updateMarkerCoalesced` routes through
`performCoalescedUndoable` keyed on the marker id so a name-typing burst (or a
future colour-picker drag) folds into one undo step.

A selection helper:

```swift
var selectedMarkerID: TimelineMarker.ID?
var selectedMarker: TimelineMarker? { ... }
```

Snapshot restoration preserves the `selectedMarkerID` so undo brings the same
marker back into focus.

## Trade-offs

- **Markers on `Project` (not a `MarkerTrack`).** Markers are a single global
  list — they're annotations on time, not parallel lanes the way caption tracks
  are. A `MarkerTrack` would only matter once Phase 34 produces multiple beat
  *series* the user wants to mute independently; defer until that emerges.
- **Optional `colour` rather than a "marker kind" enum.** Phase 34 can paint
  beats yellow, Phase 44 can paint chapters green, hand-placed markers stay on
  the system accent. A free-form colour beats a closed kind enum for the same
  zero-cost storage.
- **Single sorted array, sort on insert.** O(n) inserts are fine at the
  expected scale (hundreds of beat markers per song); a binary-search insertion
  point would buy us nothing visible.
- **Delete key only when a marker is selected.** Re-overloading the existing
  Delete shortcut (which already deletes the selected clip / transition) means
  the user gets exactly one Delete behaviour: it acts on whatever is selected.
  No new shortcut to memorise.

## Risks

- Two markers at the same `time` would draw on top of each other; the inspector
  row stays distinct (by `id`) but the timeline label collides. Acceptable for
  v1 — Phase 34's beat output is monotonic so this only happens with
  user-placed markers, and the inspector remains the canonical edit surface.
- `Shift+M` collides with the system-wide "minimise" shortcut only when
  modifiers include `Command`; ours is `Shift` alone, which is free.
- A keyboard-only user must be able to reach the rename popover without the
  pointer — the inspector text field is the keyboard-accessible alternative
  and stays in sync.

## Non-goals

- Marker import from a sidecar file (CSV, JSON, FCPX `.fcpxml` chapters).
  Phase 48 (OTIO interchange) is the right home for that.
- Per-marker comments / multi-line notes — the name + optional colour is the
  v1 surface; longer notes belong in a future "marker inspector" detail view.
- Snapping the playhead to markers when scrubbing. Markers can be snap targets
  in a follow-up; this spec lands the data + drawing, not the scrubber math.
- A "go to next/previous marker" keyboard navigation (`'`/`;` in browser-
  editor). Trivial to add later once the marker list lives somewhere stable.
