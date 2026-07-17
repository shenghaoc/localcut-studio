# Requirements: Design-System Integration Polish

## R1 — Shared panel header

- **R1.1** A reusable `EditorPanelHeader` renders a `.headline` title with an
  optional trailing `@ViewBuilder` slot, 12 pt horizontal padding, and a
  `verticalPadding` parameter defaulting to 8. The Timeline passes 6 to keep
  its gutter/ruler alignment identical to the prior hand-rolled header. The
  header draws no `Divider`; call sites own their separators.
- **R1.2** The title carries the `.isHeader` accessibility trait so VoiceOver
  rotor heading navigation reaches each primary pane.
- **R1.3** A trailing-less convenience init (`Trailing == EmptyView`) covers
  headers with no actions.
- **R1.4** Media bin and Timeline headers are expressed through
  `EditorPanelHeader`; each call site keeps its own surrounding separator. The
  Inspector side rail uses its segmented pane switcher as the single visible
  and VoiceOver heading so the active pane is not announced twice.

## R2 — Timeline chrome

- **R2.1** The timeline header shows a compact title plus, in the trailing
  slot, the page-left / center-playhead / page-right buttons and the zoom
  slider; the scroll viewport also exposes an `accessibilityAdjustableAction`
  so VoiceOver rotor "Adjust value" pages left/right. No per-frame summary
  string is computed during view updates.
- **R2.2** A `PlayheadHead` triangle is drawn at the ruler/lane boundary,
  centred on the playhead `x`, alongside the full-height scrub line.
- **R2.3** The playhead head is an interactive grab target with a `DragGesture`
  (tolerant seek while dragging, precise seek on end). The full-height scrub
  line stays non-interactive (`allowsHitTesting(false)`) so clicks fall
  through to clips and the ruler; the head carries `accessibilityHidden(true)`.
  The ruler remains an accessible scrub target with a label, live playhead
  value, and adjustable action for VoiceOver users.

## R3 — Inspector media imagery

- **R3.1** Clip and Media inspector sections lead with `InspectorPosterView`.
- **R3.2** The poster shows the media thumbnail when present, otherwise a
  `film` / `waveform` SF Symbol on a `.quaternary` plate.
- **R3.3** The poster is decorative (`accessibilityHidden`); readable metadata
  stays on the labelled rows.

## R4 — Render-queue preset metadata

- **R4.1** `presetSubtitle` reads `container • codec • size • aspect • bitrate`;
  unknown codec strings are upper-cased.
- **R4.2** The preset subtitle is single-line with tail truncation so the five
  segments don't wrap in a narrow inspector.
- **R4.3** A job's output name is single-line with middle truncation.

## R5 — Accessibility

- **R5.1** Containers with a custom label use `children: .ignore` so the label
  is announced once (media-bin rows, preview, timeline track/caption rows).
- **R5.2** Track and caption-track labels use `AttributedString(localized:)`
  with `inflect: true` for plural agreement instead of manual pluralization. A
  muted caption track uses a full localized variant (not an appended `, muted`)
  so the suffix is translator-reorderable.
- **R5.3** The preview exposes a localized `accessibilityValue` for the empty
  and active states; the transport time reads as "Playhead … of …".
- **R5.4** Timeline clip blocks and transition glyphs are keyboard-focusable.
  Focus selects the corresponding element, Delete reaches the timeline-scoped
  command, and VoiceOver announces transition selection state.

## R6 — Quality gate

- **R6.1** The Debug/macOS app target compiles successfully with no source
  diagnostics introduced by this spec.
- **R6.2** The full test suite stays green with no count regression. Pure tests
  cover the ruler adjustment step and project-boundary clamping.
- **R6.3** No model field, schema version, or composition time-range math
  changes; the standalone `app/` prototype is not merged.

## R7 — Final review hardening

- **R7.1** Failure paths hardened in this pass (native pickers; media/caption
  import; project open/save; preview, replay, program-source, and silence work;
  OTIO/EDL export) preserve the underlying error detail, add one actionable
  recovery suggestion without duplicate punctuation, and keep intentional
  cancellation silent. Batch-import announcements stay bounded, while a
  truncated status line exposes the full message through pointer help and its
  accessibility label.
- **R7.2** Shared keyframe navigation derives previous/next availability with
  the same tolerance as its seek action. Disabled controls explain why in both
  pointer help and accessibility hints.
- **R7.3** Collapsible grouped Forms do not wrap nested `Section` containers or
  duplicate visual/VoiceOver headings.
- **R7.4** Caption timing controls reflow vertically when the inspector cannot
  fit their scaled horizontal layout.
- **R7.5** Design context accurately records system-adaptive chrome and native
  control accent, functional HUD glass, distinct content/chrome badge recipes,
  and only shipping primitives.
- **R7.6** The destructive transition action uses “Delete Transition”
  consistently in menus, inspector copy, undo naming, and completion status.
- **R7.7** Adjacent recorder controls expose distinct labels: “Microphone” for
  the enable toggle and “Input Device” for microphone device selection.
- **R7.8** Split, trim, beat-cut, and silence-removal edits preserve source-local
  look-effect Bezier curves even when their handles overshoot the rendered
  strength range; effect evaluation remains bounded at render time.
