# Bugfix: Implemented-Spec Reachability & UX Polish

A cross-cutting audit of **every implemented spec** (Phase 1 + the colour-grading, colour-management,
skin-smoothing, transitions, trim/drag, keyframes, caption, title-raster, markers, diagnostics,
capability-tiers, render-cache, audio-master-bus, export-queue, project-persistence, and
project-bundle features) for anything *left over, deferred, incorrect, or improvable with the
current toolchain*. Where PR #31 hardened the **language and platform** (zero warnings, Swift 6,
macOS 26 deprecations) without changing behaviour, this pass changes **behaviour for the better**:
it surfaces shipped-but-unreachable features and closes the highest-value UX and correctness gaps
the audit found.

**The recurring finding:** several features shipped a complete, tested *engine* but no reachable
*surface*. The capability resolver is computed once at launch and read by nothing. LUTs apply with
no on-screen indication and silently stack on re-import. Markers can be added but not traversed.
Finished renders can't be revealed; failed ones can't be retried. Scopes draw without a reference
graticule. The audio fader the design specified as log-mapped shipped linear. This spec lands the
missing surfaces and a set of low-risk correctness fixes; the larger structural items the audit
turned up are catalogued under **Deferred follow-ups** with enough detail to spec them later.

**Platform:** target & CI are macOS 26 (`MACOSX_DEPLOYMENT_TARGET = 26.0`); dev host is macOS 27.
Every API used below is available on macOS 26. Per PR #31's lesson, the **CI build log is the
authoritative zero-warning gate**; this branch has also been locally verified with `xcodebuild test`
on macOS using the macOS 26.5 SDK.

**Scope discipline:** changes are additive SwiftUI + small, unit-tested pure helpers + view-layer
data plumbing. The initial pass avoided composition time-range math; the follow-up snap fix touches
only pure `TransitionLayout` authored/effective mapping and is covered by unit tests. New logic ships
with tests and the test count only grows.

---

## Reachability — surface features that shipped without a UI

### S1 — Capability tiers are computed but read by nothing

`Capabilities.current` (a `nonisolated static let` probed once at launch) resolves a
`baseline`/`accelerated`/`pro` verdict + human-readable reason per feature, but a project-wide grep
finds **no consumer outside `Capabilities.swift`** — neither `feature-capability-tiers` nor
`feature-diagnostics` actually surfaced it (each spec pointed at the other). The reason strings,
engineered to always be non-empty and explain *why* a feature is degraded, reach no user.

- **Fix:** Add a "Capabilities" section to `DiagnosticsView` — the agreed home
  (feature-capability-tiers R3.3, feature-diagnostics) — listing the tier for `.metalEffectChain`,
  `.frameInterpolation`, and `.simultaneousCaptureStreams(count: 2)`, each verdict's `reason` in
  `.help`. Pure read of a `Sendable` snapshot; no concurrency risk. The engine stays SwiftUI-free —
  the tier label + tint mapping lives in the view.

### S2 — LUTs apply invisibly and stack silently on re-import

`importLUT` did `effects.append(.lut(...))` with no dedup, so a second import stacked a second cube,
applied in sequence, with zero UI feedback. The Colour section showed only "Import LUT…" — no
filename, no "a LUT is active" indicator, and no way to remove just the LUT (only the section-wide
"Reset", which also wipes the grade). feature-colour-grading R1.2 specifies **one** LUT slot.

- **Fix:** A clip holds one LUT. `importLUT` now **replaces** the slot (`[Effect].replacingLUT`);
  the Colour section shows the import-time filename from a session cache with a remove (✕) control
  (`removeLUT` / `[Effect].removingLUT`), and the import button reads "Replace LUT…" when one is
  present. Reopened projects avoid main-actor bookmark resolution and show a generic applied label
  until the LUT is re-imported in the session.

### S3 — Markers can be added but not traversed

`feature-markers` shipped add/rename/delete/seek but explicitly deferred next/previous navigation
("trivial to add later once the marker list lives somewhere stable" — it now lives in the sorted
`Project.markers`). A keyboard/menu user couldn't jump between markers — a core NLE expectation.

- **Fix:** `selectNextMarker()` / `selectPreviousMarker()` on `EditorModel` seek to the nearest
  marker after/before the playhead (the list is kept sorted), exposed as Edit-menu commands
  **⌘⇧]** / **⌘⇧[**, disabled when there are no markers.

### S4 — Finished renders can't be revealed; failed renders can't be retried

The render-queue inspector had only a cancel button. A completed render couldn't be opened in
Finder; a `.failed`/`.cancelled` row was a dead end even though `RenderQueue` keeps the snapshot +
destination bookmark — feature-export-queue R3.3 explicitly promises "the user keeps the row to
retry against a destination."

- **Fix:** `RenderQueue.retry(jobID:)` requeues a terminal job (reusing snapshot + bookmark);
  `RenderQueue.outputURL(forJobID:)` resolves the bookmark so the inspector can
  `NSWorkspace.activateFileViewerSelecting`. The inspector gains **Reveal in Finder** on completed
  rows and **Retry** on failed/cancelled rows.

---

## UX polish

### U1 — Per-parameter slider reset (NLE-standard)

Colour, beauty, opacity, and gain sliders could only be reset section-wide; an individual parameter
couldn't be returned to neutral. `LabeledSliderRow` gains an opt-in `resetAction` that attaches a
right-click **Reset** context menu. Wired for the five colour-grade parameters, clip opacity, and
master/track gain (each resetting to its documented neutral and committing one undo step). Beauty
keeps its section reset (its neutral mask values aren't an obvious single number).

### U2 — Wide-gamut working space carries no advisory

feature-colour-management's design risk says to keep sRGB the default and "document the others as
'advanced — verify on a reference monitor'." The picker listed all four spaces flat with no caveat.

- **Fix:** A `.help` on the Working Space picker and a caption footnote shown when a non-sRGB space
  is selected.

### U3 — Scopes have no reference graticule

The waveform drew a bare outline (no IRE scale); the vectorscope had only an outer circle. Below the
pro-tool bar ui-standards sets.

- **Fix:** Horizontal IRE reference lines (0/25/50/75/100) with labels on the waveform; a
  75%-saturation reference ring on the vectorscope. Static overlays drawn behind the live trace — no
  per-frame sampling cost. (Per-pixel vectorscope scatter + colour-target boxes remain a Phase-38
  item — see D-list.)

### U4 — Audio fader is linear, not the specified log/dB mapping

feature-audio-master-bus's design specifies a "−∞…+6 dB log-mapped" master fader; both master and
track gain shipped as linear `0…2` sliders, cramping all useful control around unity. The dB *label*
was honest but the *control* wasn't log-mapped.

- **Fix:** `AudioGainMapping` (pure, unit-tested) maps the sliders in dB space (−60…+6 dB) ↔ linear
  amplitude, so equal travel is equal dB. Model gain values are unchanged — only the slider's
  get/set transform — so all existing gain-math tests and the default-project bit-identity invariant
  are untouched.

### U5 — Captions: track rename + burn-in notice missing

feature-caption-tracks R2.6 promises the user "can rename" an imported track, but the track name was
non-editable. R6.2 promises the UI states styling is preview/burn-in only — no such statement
existed.

- **Fix:** A `renameCaptionTrack` command (coalesced, rebuild-skipped) behind an inspector
  `TextField`; a one-line caption stating caption styling is preview/burn-in only while SRT/VTT
  sidecars stay plain text.

### U6 — Wipe transitions had no direction control

feature-transitions R1.2 calls the wipe transition directional, but `TransitionType.wipe` used the
Core Image bars-swipe default angle and the inspector exposed only type/duration. Users could choose
"Wipe" but not its direction.

- **Fix:** `Transition` now stores a `wipeAngle` in radians, persisted through `TransitionDoc` with
  a legacy default for older projects. The transition inspector shows a wipe-only Direction slider
  in degrees, and the shared compositor maps the stored radians to
  `CIFilter.barsSwipeTransition().angle`, so preview and export stay identical.

### U7 — Caption line retiming existed in the model but had no surface

feature-caption-tracks R4.1 includes retiming caption lines, and `CaptionTrack.updateLine` already
re-sorts edited lines. The inspector only exposed text editing and delete, and the timeline had no
caption lane, so timing edits were not reachable.

- **Fix:** `retimeCaptionLine` updates a line through the existing coalesced `updateCaptionLine`
  path, preserving undo and sorted order. The caption inspector now exposes Start and Duration
  fields, and the timeline draws one caption lane per track with draggable caption blocks. Caption
  line times stay in effective/rendered timeline space, matching how the compositor schedules them.

### U8 — Skin-smooth strength keyframes had no authoring surface

feature-keyframes shipped the generic `Keyframed<Float>` model and skin-smooth strength already
evaluates through it in the compositor, but the inspector exposed only the static default strength.
Users could open a project with keyframes and see the animated render, but could not create or edit a
skin-smooth keyframe.

- **Fix:** `EditorModel` now exposes selected-clip skin-smooth strength keyframe commands at the
  clip-local playhead: add/update using the current default strength, remove at the playhead, and
  previous/next keyframe seek. The Beauty inspector shows the local playhead time, current evaluated
  value, count, and compact controls. The generic timeline-lane/keyframe-curve editor remains a
  deferred feature; this lands the minimal reachable authoring path for the existing animated
  parameter.

### U9 — Live audio meter did not start with the editor

feature-audio-master-bus added a live `AVAudioEngine` graph and inspector meter, but `prepareLive()`
was never called from the app shell. The inspector therefore stayed in its "not connected" state for
normal use even though the bus lifecycle was implemented.

- **Fix:** `EditorView` starts the live bus on appear and tears it down on disappear through
  `EditorModel.prepareAudioMetering()` / `teardownAudioMetering()`. Start failures are surfaced in
  the status line and the inspector. Export-time offline meter animation is intentionally re-scoped:
  the default export path still uses `AVAssetExportSession`, which exposes progress but not PCM
  blocks to feed the offline bus tap. Driving the meter during export belongs with Phase 36's
  `AVAssetReader`/`AVAssetWriter` audio path.

### U10 — Cache LRU bookkeeping was O(n), and render-cache disk spill was empty

feature-render-cache described an ordered LRU and wired a Caches-directory accessor, but each cache
touch/evict still used array scans (`firstIndex`, `removeFirst`) and evicted render frames were lost
instead of spilling to disk. feature-title-raster had the same array-backed LRU shape.

- **Fix:** `RenderCache` and `TitleRasterer` now use lock-confined doubly-linked LRU nodes, making
  hit touches and overflow eviction O(1). `RenderCache` also writes evicted frames to a bounded PNG
  disk tier under the app Caches directory, rehydrates them on memory miss, and removes spill files on
  invalidate/purge. The disk tier is in-session only because the effect-chain hash remains
  process-seeded.

---

## Correctness

### C1 — Cancelling a running export leaves a partial file (P0 release gate)

`AVAssetExportSession.cancelExport()` leaves the partially-written file at the user's path (the
`AVAssetWriter` fallback cleans up after itself; the session path does not). `RELEASE-READINESS.md`
lists "cancelling an export leaves no partial file at the user's path" as a gate, and
feature-export-queue R2.4 requires it.

- **Fix:** `runJob` deletes the output on cancel via `removePartialOutput()`, **guarded by a
  `didBeginEncoding` flag** set only after the deliberate overwrite. The three post-encode cancel
  arms (cancel-after-write, `CancellationError`, generic-error-as-cancel) clean up the partial write;
  a cancel that lands *before* encoding — e.g. while `CompositionBuilder.build` is still awaiting and
  throws `CancellationError` — leaves the user's **pre-existing** file intact. (The flag guard was
  added in review: without it the `CancellationError` arm could delete a pre-existing file when
  nothing had been written.)

### C2 — Karaoke word highlight drops to base fill in inter-word gaps

`activeWordIndex` returned `nil` whenever the playhead sat between two `WordTiming` ranges or past
the last word — so the highlight visibly flickered back to the un-highlighted fill in the gaps ASR
routinely leaves, and after the final word while the line was still on screen (phase-30 R3.3 wants
≤ 1-frame desync, not a flicker).

- **Fix:** A word whose range contains the time still wins; otherwise the **most-recently-started**
  word is held, clamped to the last word for the line's tail. Before the first word starts it stays
  idle (nil). Factored to a `static` pure function and unit-tested.

### C3 — Render-size change doesn't purge the caption raster cache

feature-title-raster R2.3 / T1.4 says the editor calls `purge()` on render-size change;
`setWorkingColourSpace` did, but `setRenderSize` did not, leaving old-resolution rasters resident
until LRU eviction. (Not a stale-bitmap bug — render size is in the raster cache key — but it
contradicts the documented call site and wastes memory.)

- **Fix:** `setRenderSize` now calls `EffectCompositor.purgeCaptionRasterCache()` inside its
  undoable block.

### C4 — Snap-to-playhead used the wrong coordinate space when transitions exist

`EditorModel.snapTargets` mixed authored clip-edge targets with the playhead's effective
(rippled/rendered) time. Once a transition ripples the timeline, snapping a trim or drag candidate to
the playhead could land one transition-overlap early. Inside a transition window one effective
playhead legitimately maps to both sides of the cut, so a single global authored time is not enough.

- **Fix:** `TransitionLayout.authoredTimes(forEffective:cuts:)` returns every authored time that
  renders at the effective playhead. Outside overlaps this is one target; inside an overlap it is
  both the outgoing and incoming side. `snapTargets` now adds those authored playhead target(s) while
  leaving clip boundaries authored, so trim/drag candidates snap to the side of the transition they
  are actually manipulating.

---

## Verification

- **V1** — Debug/macOS build (app + tests): zero warnings, zero errors on the macOS 26 / Xcode 26.5
  CI toolchain (authoritative gate per PR #31) and on a local macOS `xcodebuild test` run with
  `-derivedDataPath /private/tmp/LocalCutStudio-DerivedData`.
- **V2** — Full test suite green with **no count regression**. New tests:
  `[Effect].replacingLUT/removingLUT/hasLUT` + LUT display-name cache pruning (4),
  `AudioGainMapping` round-trip + floor + slider-minimum reachability (4),
  `EffectCompositor.activeWordIndex` gap-hold + empty (2), marker next/prev nav + exact-on-marker
  navigation (3), `RenderQueue.retry` requeues cancelled + failed jobs and no-ops for non-terminal
  rows (3), `renameCaptionTrack` undo (1), `TransitionLayout.authoredTimes` and transition-aware
  snap-to-playhead conversion (2), directional wipe angle planning + persistence/bundle migration
  + shared video-composition propagation (5), caption-line retiming (1), skin-smooth keyframe
  authoring/navigation (2), render-cache disk spill and title-raster LRU touch ordering (2).
- **V3** — Manual smoke (recommended pre-release): Diagnostics shows capability tiers with reasons in
  `.help`; LUT import shows the filename and replacing it doesn't stack; ⌘⇧[ / ⌘⇧] jump markers;
  Reveal/Retry behave; scopes show the graticule; the master fader feels log-mapped; cancelling an
  export leaves no file behind.

---

## Deferred follow-ups (audit findings not in this PR)

Catalogued so the audit's value isn't lost. Each is either higher-risk (composition math, behaviour
change to a tuned look), or large enough to deserve its own spec.

**Correctness / behaviour (own spec recommended):**
- **Skin-smooth resolution independence** — blur radius is `strength * 10` in source pixels, so the
  same clip smooths differently at 1080p vs 4K source. Scaling by image height changes the look of
  existing projects; needs a design decision, not a silent change.

**Deferred feature surfaces:**
- **Keyframable caption style params** (phase-30 R2.3) — `CaptionStyle` stores plain values, no
  `Keyframed<T>` fields; the requirement is silently unmet.
- **Export-time offline audio meter animation** (audio-master-bus R3.3) — export still runs through
  `AVAssetExportSession`, which has progress but no PCM callback for the offline bus tap. Phase 36's
  reader/writer audio pipeline owns the point where rendered blocks can update the meter.

**Performance / toolchain:**
- **Scopes:** revision-gated redraw (the sampler exposes `revision`, the view ignores it and repaints
  at 30 Hz when paused); single-pass histogram; per-pixel vectorscope scatter + colour-target boxes.
- **Document model:** evaluate `ReferenceFileDocument`/`DocumentGroup` (Open Recent, async save);
  async window-close save (multi-GB bundle IO currently blocks the close prompt); staged
  `fingerprints.json`+`project.json` swap; bundle-open verify progress.

**Smaller hygiene:**
- Bundle "Don't copy" import toggle (`wantsBundling` is dead in the UI); stale-bookmark refresh on
  the queue path; `RenderQueue.isRunning` reset TOCTOU; typewriter mask excludes the pill; word-range
  by token index instead of substring scan; golden snapshot tests (skin-smooth T3.1, caption presets
  T5.1).
