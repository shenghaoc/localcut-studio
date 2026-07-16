# Requirements: Phase 43 — Screencast Post Pack

## R1 — Zoom-n-pan presets

- **R1.1** Each preset stamps an editable `Keyframed<Transform2D>` track containing `[Keyframe<Transform2D>]` on the clip.
- **R1.2** Pan velocity and acceleration are bounded; documented thresholds prevent whip-motion.
- **R1.3** After applying a preset, the user can edit, add, or delete the resulting keyframes like any hand-authored set.

## R2 — Capture event log

- **R2.1** When recording LocalCut Studio itself, the session writes a sidecar `events.json` with timestamped mouse / scroll / key-code events.
- **R2.2** Display, window, and non-own app recordings write mouse / scroll events when the event can be mapped into the capture target; non-own app targets use display coordinate space and do not capture cross-app keys or text.
- **R2.3** Event capture uses `NSEvent` local/global monitors only; no Accessibility permission prompt.
- **R2.4** The event log persists with the session and survives bundle round-trip.
- **R2.5** Pause/resume and source-switch lifecycles stop, restart, or retarget event monitoring so events do not double-log across session state changes.

## R3 — Auto-zoom proposals

- **R3.1** A panel reads a landed capture sidecar or imported standalone event log, clusters click bursts, and proposes zoom-n-pan keyframes.
- **R3.2** Each proposal is review-before-apply (apply / skip); nothing auto-applies.
- **R3.3** Proposals are deterministic given the same event log and clustering parameters.

## R4 — Callouts

- **R4.1** Arrow, box, step-number, spotlight, blur-region callout kinds.
- **R4.2** All callouts support `Transform2D` keyframe animation. Stored handles drive temporal Bezier easing in both the inspector and the shared preview/export compositor; tracks without handles remain linear.
- **R4.3** Blur-region honours `[Keyframe<Transform2D>]` so it can track a moving feature.

## R5 — Padded background

- **R5.1** Preset offers gradient or image background, rounded-corner clip frame, drop shadow, inset margin.
- **R5.2** Background images downsample lazily on first render to the current canvas's maximum pixel dimension, then use a bounded cache keyed by bookmark and render dimension that can be purged under memory pressure.
- **R5.3** Background images persist as security-scoped bookmarks for single-file projects and bundle-relative assets for `.lcbundle` projects and render-queue snapshots.
- **R5.4** Realtime at 1080p on the accelerated tier with the preset on.

## R6 — Verification

- **R6.1** Snapshot tests for each callout kind on a fixture clip.
- **R6.2** Determinism test on the auto-zoom proposal output for a fixture event log.
- **R6.3** Smoke: capture session → events captured or imported → auto-zoom proposed → apply → keyframes editable → export.
- **R6.4** `xcodebuild` (Debug, macOS) green; no test count regression.
- **R6.5** Focused tests prove temporal Bezier easing and linear fallback for clip and callout transform tracks.
