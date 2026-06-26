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
with no actions (Inspector).

### Timeline chrome

- The timeline header collapses to the design-system shape: compact title plus
  the zoom slider in the trailing slot (no summary line).
- `PlayheadHead` — a small downward triangle pinned to the ruler/lane boundary,
  centred on the scrub `x`. The precise 1.5 pt red line still spans the full
  height; the head is the design-system grab affordance. Both live in the
  isolated `PlayheadView` so they re-evaluate per `currentTime` tick without
  invalidating the rest of the timeline. The head is decorative
  (`allowsHitTesting(false)`).

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

## Non-goals

Real AVFoundation playback/export, trim/drag, and the inspector feature
surfaces already exist in the app and are untouched. The standalone `app/`
prototype is **not** merged. No new model fields, no schema bump, no test-count
regression.
