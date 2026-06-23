# Design: Implemented-Spec Reachability & UX Polish

How each item in `bugfix.md` is implemented. The guiding constraints: additive SwiftUI + small
pure helpers that are unit-testable; no new files (so the `.xcodeproj` is untouched and there is no
target-membership risk); no edits to composition time-range math; new logic is `nonisolated` where
it must be callable from both the MainActor UI and nonisolated engine/tests (mirroring the existing
`[Effect].renderCacheHash` pattern).

## Engine / model

### `[Effect]` LUT-slot helpers — `Models.swift`
`nonisolated` extension on `Array where Element == Effect`:
- `hasLUT` — presence check.
- `replacingLUT(bookmark:)` — replaces the existing `.lut` in place, else appends (one LUT per clip,
  R1.2). This is the behaviour change vs the old `append`.
- `removingLUT()` — filters out `.lut`, preserving grade / skin-smooth.

Pure value transforms, so they're tested directly (no security-scoped bookmark needed). `importLUT`
and the new `removeLUT` call them; `selectedClipHasLUT` plus an import-time filename cache drive the
inspector indicator without resolving security-scoped bookmarks from `selectedClipLUTName`. That
cache is pruned to active LUT bookmarks after replace/remove so a long session does not retain names
for LUTs no clip references anymore.

### Marker navigation — `EditorModel+Markers.swift`
`selectNextMarker()` / `selectPreviousMarker()` use `project.markers.first(where: $0.time > now)` /
`last(where: $0.time < now)` (the list is sorted) and route through the existing `seekToMarker(id:)`
funnel, so selection exclusivity + the past-duration seek behaviour are inherited.

### Transition-aware snap targets — `TransitionLayout.swift` / `EditorModel.swift`
`TransitionLayout.authoredTimes(forEffective:cuts:)` inverts the authored-to-effective transition
ripple used by placements. It returns one authored time outside transition windows and both authored
sides inside a transition overlap. `EditorModel.snapTargets` feeds the effective playhead through
that inverse before appending it to the authored clip-edge targets, so trim/drag candidates remain in
one coordinate space.

### Directional wipe — `Transition` / `CompositionBuilder` / `EffectCompositor`
`Transition.wipeAngle` stores the bars-swipe angle in radians. `TransitionDoc` decodes missing
angles to `Transition.defaultWipeAngle`, so pre-direction documents open unchanged. `CompositionBuilder`
threads the angle through `VisibleSegment` / `PlannedUnit` / `RenderUnit`, and `EffectCompositor`
sets `CIFilter.barsSwipeTransition().angle`; no preview/export fork is introduced.

### Caption rename — `EditorModel+Captions.swift`
`renameCaptionTrack(_:in:)` mirrors `updateMarkerCoalesced`: `performCoalescedUndoable(target:
trackID, rebuild: .skip)` so per-keystroke edits fold into one undo step and the name (which doesn't
affect rendering) skips the composition rebuild.

### Caption retiming — `EditorModel+Captions.swift`
`retimeCaptionLine(_:in:start:duration:)` looks up the current line by id, clamps start to zero and
duration to at least one frame, shifts word timings by the same delta when the line start moves, then
calls `updateCaptionLine` so sorting, undo coalescing, and rebuild scheduling stay in the existing
caption mutation path.

### Word-highlight hold — `EffectCompositor.swift`
`activeWordIndex` becomes a thin instance wrapper over a new `static nonisolated
activeWordIndex(words:at:)`: containment match first, else hold the most-recently-started word, else
nil before the first word. `static` + pure so it's unit-tested without a compositor instance.

### Export-queue — `RenderQueue.swift`
- `removePartialOutput` closure (captures the resolved `outputURL`) called in the three post-encode
  cancel arms in `runJob` — never the pre-encode arm (nothing written yet there).
- `retry(jobID:autoStart:)` — flips a `.failed`/`.cancelled` job to `.queued`, clears
  error/progress/runtime, persists, and (by default) `start()`s. No-op for non-terminal/completed.
- `outputURL(forJobID:)` — public resolve of the job's bookmark for Reveal-in-Finder.

### Audio gain mapping — `AudioInspectorView.swift`
`nonisolated enum AudioGainMapping` with `decibels(fromLinear:)` / `linear(fromDecibels:)` over a
−60…+6 dB range (−60 dB ⇄ silence). Only the slider bindings change; `setMasterGain` / `setTrackInput`
and all stored gains stay linear, so the audio engine and its tests are unaffected.

### `setRenderSize` cache purge — `EditorModel.swift`
One added `EffectCompositor.purgeCaptionRasterCache()` inside the existing undoable block, matching
`setWorkingColourSpace`.

## Views

### `LabeledSliderRow.swift`
New opt-in `resetAction: (() -> Void)?`. When set, `body` wraps the row in a `.contextMenu` with a
single "Reset" button; when nil, the row is unchanged. The caller owns the reset (set value through
the model + commit) so the row stays model-agnostic. `body` is the implicit `@ViewBuilder`, so the
if/else is `_ConditionalContent`.

### `InspectorView.swift`
- Colour rows pass `resetAction: resetColourGrade(\.kp, to: neutral)` (a helper returning a closure
  that sets the coalesced binding then commits). Opacity row resets to 1.
- LUT indicator: a conditional `LabeledContent("LUT")` showing the filename + a destructive ✕
  (`removeLUT`); the import button label flips to "Replace LUT…".
- Working-space `.help` + a caption shown when `workingColourSpace != .sRGB`.
- Transition section: wipe-only Direction slider in degrees, with right-click reset to the legacy
  default angle.

### `ScopesView.swift`
- `drawWaveformGraticule` — five horizontal lines + IRE labels, drawn after the frame outline and
  behind the trace.
- Vectorscope — an inner ellipse at 75% radius (`plot.insetBy` 12.5% per side).

### `DiagnosticsView.swift`
`capabilitiesSection` reads `Capabilities.current` and renders a `capabilityRow` per feature with
`tierLabel`/`tierTint` (view-local, keeping `Capabilities.swift` SwiftUI-free) and the verdict
`reason` in `.help`.

### `CaptionsInspectorView.swift`
Rename `TextField` at the top of each track's disclosure (bound to `renameCaptionTrack`); a burn-in
caption after the track list. Each line row exposes compact Start and Duration second fields bound
to `retimeCaptionLine`.

### `TimelineView.swift`
Caption tracks render as lightweight lanes below video/audio tracks. Caption blocks are positioned
by `CaptionLine.range` in effective timeline coordinates and can be dragged horizontally to retime
their start; context actions can move a line to the playhead or delete it. The lane intentionally
does not use authored clip-edge snap targets because captions are scheduled directly in the rendered
timeline.

### `RenderQueueInspectorView.swift`
Reveal-in-Finder button on `.completed` rows (`NSWorkspace.activateFileViewerSelecting` via
`outputURL(forJobID:)`); Retry button on `.failed`/`.cancelled` rows (`retry(jobID:)`).

### `ContentView.swift`
Previous/Next Marker commands in the Edit group (⌘⇧[ / ⌘⇧]), disabled when `markers.isEmpty`.
Modified chords (not bare `[`/`]`) so they don't fire while typing in a text field.

## Testing
New tests extend existing suites (no new files): `EffectsTests` (LUT helpers + filename-cache pruning),
`AudioMasterBusTests` (gain mapping + reachable silence floor), `CaptionsAndKeyframesTests`
(word-highlight + rename), `MarkersTests` (nav, including exact-on-marker movement),
`ExportQueueTests` (retry for cancelled + failed jobs), `TransitionsTests`/`TrimAndDragTests`
(transition-window authored inverse + snap-through-ripple; directional wipe angle render planning),
`TransitionsIntegrationTests` (angle reaches the shared video composition), `PersistenceTests`/
`ProjectBundleTests` (transition-angle document and bundle round trips), `CaptionsAndKeyframesTests`
(caption-line retiming sort/undo/word shift). Pure helpers are tested directly; MainActor commands
via `EditorModel`.

## Risks
- **Build gate** — verified with local `xcodebuild test` on macOS using the macOS 26.5 SDK; CI remains
  the authoritative zero-warning gate. The biggest behaviour change (U4 dB fader) is isolated to two
  bindings + a tested pure mapping and is trivially revertible.
- **Transition snap math** is P0-sensitive, but the fix is a pure inverse of the existing cut list:
  it does not alter composition assembly, transition overlaps, or preview/export render paths.
- **Reopened-project LUT names** fall back to a generic "Applied" label because the inspector avoids
  resolving security-scoped bookmarks on the main actor; a new import refreshes the session cache.
