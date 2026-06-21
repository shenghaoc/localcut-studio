# Tasks: Phase 43 — Screencast Post Pack

> Status: **Proposed**. Depends on Phase 41, keyframes, title raster path.

## Zoom-n-pan

- [ ] **T1.1** Define preset library (slow zoom-in, pan, snap-zoom-on-click, etc.).
- [ ] **T1.2** Stamp `[Keyframe<CGAffineTransform>]` on the selected clip.
- [ ] **T1.3** Enforce velocity / acceleration bounds at stamp time.

## Event log

- [ ] **T2.1** Own-process input via `NSEvent.addLocalMonitorForEvents`; write `events.json` sidecar alongside the session manifest. No Accessibility entitlement required.
- [ ] **T2.2** Loader + parser; integrate with the session model.
- [ ] **T2.3** Detect "own-app" target at session open; skip if not.

## Auto-zoom proposals

- [ ] **T3.1** Cluster click bursts on the event log.
- [ ] **T3.2** Generate keyframe sets per cluster; render proposal cards.
- [ ] **T3.3** Apply / skip per proposal; undoable.

## Callouts

- [ ] **T4.1** Arrow + box + step-number callout sources via title raster.
- [ ] **T4.2** Spotlight callout (radial mask) via CIKernel.
- [ ] **T4.3** Blur-region as a CIKernel under a keyframed transform.

## Padded background

- [ ] **T5.1** Preset model: background source, corner radius, shadow params, inset margin.
- [ ] **T5.2** Compositor preset application (whole-canvas layer group).
- [ ] **T5.3** Background image downsample at apply time.

## Verification

- [ ] **T6.1** Snapshot tests for each callout kind.
- [ ] **T6.2** Determinism test for auto-zoom proposals.
- [ ] **T6.3** Smoke: own-app session → propose → apply → export.
- [ ] **T6.4** `xcodebuild` (Debug, macOS) green.
