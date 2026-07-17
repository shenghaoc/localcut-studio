# Tasks: Phase 43 — Screencast Post Pack

> Status: **Implemented**. Depends on Phase 41, keyframes, title raster path.

## Zoom-n-pan

- [x] **T1.1** Define preset library (slow zoom-in, pan, snap-zoom-on-click, etc.).
- [x] **T1.2** Stamp `[Keyframe<Transform2D>]` into the selected clip's `Keyframed<Transform2D>` track.
- [x] **T1.3** Enforce velocity / acceleration bounds at stamp time.

## Event log

- [x] **T2.1** Own-process input via `NSEvent.addLocalMonitorForEvents`; write `events.json` sidecar alongside the session manifest. No Accessibility entitlement required.
- [x] **T2.2** Loader + parser; integrate with the session model.
- [x] **T2.3** Display/window/non-own-app mouse and scroll capture via `NSEvent.addGlobalMonitorForEvents`; no cross-app keys/text and no Accessibility permission.
- [x] **T2.4** Pause/resume and source-switch lifecycle retargets event monitoring without duplicate monitors.

## Auto-zoom proposals

- [x] **T3.1** Cluster click bursts on the event log.
- [x] **T3.2** Generate keyframe sets per cluster; render proposal cards.
- [x] **T3.3** Apply / skip per proposal; undoable.
- [x] **T3.4** Standalone `events.json` import path for generating proposals without a fresh capture session.

## Callouts

- [x] **T4.1** Arrow + box + step-number callout sources via title raster.
- [x] **T4.2** Spotlight callout (radial mask) via CIKernel.
- [x] **T4.3** Blur-region as a CIKernel under a keyframed transform.
- [x] **T4.4** Inspector UI for static callout transforms and add/update/delete/seek/edit transform keyframes; stored handles drive the same temporal Bezier evaluator used by preview and export.

## Padded background

- [x] **T5.1** Preset model: background source, corner radius, shadow params, inset margin.
- [x] **T5.2** Compositor preset application (whole-canvas layer group).
- [x] **T5.3** Lazy first-render ImageIO downsampling to the requested canvas dimension, with a bounded bookmark-and-dimension cache and memory-pressure purge.
- [x] **T5.4** Background image picker, security-scoped single-file persistence, bundle-relative `.lcbundle` persistence, and render-queue snapshot restoration.

## Verification

- [x] **T6.1** Snapshot tests for each callout kind.
- [x] **T6.2** Determinism test for auto-zoom proposals.
- [x] **T6.3** Smoke: capture session or imported log → propose → apply → export.
- [x] **T6.4** `xcodebuild` (Debug, macOS) green.
- [x] **T6.5** Focused tests for transform temporal Bezier easing, handle-free linear fallback, and clip/callout playhead evaluation.
