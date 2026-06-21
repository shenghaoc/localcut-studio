# Requirements: Phase 43 — Screencast Post Pack

## R1 — Zoom-n-pan presets

- **R1.1** Each preset stamps editable `[Keyframe<CGAffineTransform>]` on the clip's transform.
- **R1.2** Pan velocity and acceleration are bounded; documented thresholds prevent whip-motion.
- **R1.3** After applying a preset, the user can edit, add, or delete the resulting keyframes like any hand-authored set.

## R2 — Own-app event log

- **R2.1** When recording LocalCut Studio itself, the session writes a sidecar `events.json` with timestamped mouse / scroll / key events.
- **R2.2** Event capture is own-process only; no cross-application tracking; no Accessibility permission prompt.
- **R2.3** The event log persists with the session and survives bundle round-trip.

## R3 — Auto-zoom proposals

- **R3.1** A panel reads the event log, clusters click bursts, and proposes zoom-n-pan keyframes.
- **R3.2** Each proposal is review-before-apply (apply / skip); nothing auto-applies.
- **R3.3** Proposals are deterministic given the same event log and clustering parameters.

## R4 — Callouts

- **R4.1** Arrow, box, step-number, spotlight, blur-region callout kinds.
- **R4.2** All callouts use clip transform + keyframe animation; bezier eases supported.
- **R4.3** Blur-region honours `[Keyframe<CGAffineTransform>]` so it can track a moving feature.

## R5 — Padded background

- **R5.1** Preset offers gradient or image background, rounded-corner clip frame, drop shadow, inset margin.
- **R5.2** Background images downsample to the project canvas at apply time.
- **R5.3** Realtime at 1080p on the accelerated tier with the preset on.

## R6 — Verification

- **R6.1** Snapshot tests for each callout kind on a fixture clip.
- **R6.2** Determinism test on the auto-zoom proposal output for a fixture event log.
- **R6.3** Smoke: own-app session → events captured → auto-zoom proposed → apply → keyframes editable → export.
- **R6.4** `xcodebuild` (Debug, macOS) green; no test count regression.
