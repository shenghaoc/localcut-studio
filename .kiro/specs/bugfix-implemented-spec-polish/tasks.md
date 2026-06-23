# Tasks: Implemented-Spec Reachability & UX Polish

Checked = shipped in this PR. Unchecked = catalogued follow-up (see `bugfix.md` → Deferred).

## Reachability
- [x] S1 — Surface `Capabilities.current` tiers + reasons in `DiagnosticsView` (caps R3.3 / diagnostics)
- [x] S2 — LUT is a single slot: `importLUT` replaces; inspector shows filename + remove (colour-grading R1.2/R3)
- [x] S3 — `selectNextMarker` / `selectPreviousMarker` + ⌘⇧] / ⌘⇧[ menu commands (markers)
- [x] S4 — Render queue: Reveal-in-Finder (completed) + Retry (failed/cancelled) (export-queue R3.3)

## UX
- [x] U1 — Opt-in per-parameter `resetAction` on `LabeledSliderRow`; wired for colour, opacity, gains
- [x] U2 — Working-space `.help` + non-sRGB advisory caption (colour-management design risk)
- [x] U3 — Scopes graticule: waveform IRE lines + labels, vectorscope 75% saturation ring
- [x] U4 — `AudioGainMapping`: master + track faders log-mapped in dB (audio-master-bus design)
- [x] U5 — Caption track rename + "styling is burn-in only" notice (caption-tracks R2.6 / R6.2)

## Correctness
- [x] C1 — Cancelling a running export deletes the partial file (export-queue R2.4 / release gate)
- [x] C2 — Karaoke word highlight holds across inter-word gaps + tail (phase-30 R3.3)
- [x] C3 — `setRenderSize` purges the caption raster cache (title-raster R2.3 / T1.4)

## Tests (no count regression; all extend existing suites)
- [x] `EffectsTests` — `replacingLUT` / `removingLUT` / `hasLUT`
- [x] `AudioMasterBusTests` — `AudioGainMapping` unity / round-trip / floor
- [x] `CaptionsAndKeyframesTests` — `activeWordIndex` gap-hold + empty; `renameCaptionTrack` undo
- [x] `MarkersTests` — next/prev nav + clamp-at-ends
- [x] `ExportQueueTests` — `retry` requeues cancelled; no-op for non-terminal

## Docs
- [x] `docs/keyboard-shortcuts.md` — add marker navigation (⌘⇧[ / ⌘⇧]) and refresh the table

## Review follow-ups (addressed in this PR)
- [x] Gemini — waveform IRE labels sit above their reference lines (no bisecting), top label clamped
- [x] Codex P1 — guard `removePartialOutput()` behind `didBeginEncoding` so a pre-encode cancel can't delete a pre-existing file
- [x] Codex P2 — `replacingLUT` collapses pre-existing stacked LUTs to one slot (+ test)
- [x] Codex P2 — `applyState` purges the caption raster cache on undo/redo of a resolution change (+ tests)
- [x] Codex P2 — LUT display name read from a session cache; no main-actor bookmark resolve in the inspector

## Deferred follow-ups (catalogued, not in this PR)
- [ ] Snap-to-playhead authored-time conversion when transitions exist (trim/drag R3.1) — P1
- [ ] Directional wipe: stored angle + inspector control + Codable migration (transitions R1.2)
- [ ] Skin-smooth resolution-independent blur radius (needs look decision)
- [ ] Keyframe authoring UI (feature-keyframes non-goal)
- [ ] Keyframable caption style params (phase-30 R2.3)
- [ ] Caption line retiming controls + caption timeline lane (caption-tracks R4.1)
- [ ] Live + offline audio metering wiring (`prepareLive`, export-time meter) (audio-master-bus R3.3/R5.1)
- [ ] Render-cache + title-raster O(1) LRU; render-cache disk spill (render-cache R2.3)
- [ ] Scopes: revision-gated redraw; single-pass histogram; per-pixel vectorscope + colour targets
- [ ] Document model: `ReferenceFileDocument`/Open Recent; async window-close save; staged bundle swap
- [ ] Bundle "Don't copy" import toggle; queue stale-bookmark refresh; `isRunning` TOCTOU
- [ ] Typewriter mask excludes pill; word-range by token index; golden snapshot tests (T3.1 / T5.1)
