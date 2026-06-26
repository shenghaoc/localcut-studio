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

## Verification

- [x] **T6.1** `xcodebuild test` (Debug, macOS) compiles with zero warnings and
  the full suite passes with no count regression (R6.1, R6.2).
- [x] **T6.2** Confirm no model/schema/composition change and that the
  standalone `app/` prototype is not merged (R6.3).
