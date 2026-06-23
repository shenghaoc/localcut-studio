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
- [x] U6 — Directional wipe angle stored, persisted, shown in inspector, and passed to compositor (transitions R1.2)
- [x] U7 — Caption line Start/Duration controls + draggable caption timeline lanes (caption-tracks R4.1)
- [x] U8 — Minimal skin-smooth strength keyframe authoring controls (feature-keyframes R6)
- [x] U9 — Live audio meter starts with the editor window; export meter is re-scoped to Phase 36's offline PCM path
- [x] U10 — Render/title cache LRU is O(1); render cache spills evicted frames to disk

## Correctness
- [x] C1 — Cancelling a running export deletes the partial file (export-queue R2.4 / release gate)
- [x] C2 — Karaoke word highlight holds across inter-word gaps + tail (phase-30 R3.3)
- [x] C3 — `setRenderSize` purges the caption raster cache (title-raster R2.3 / T1.4)
- [x] C4 — Snap-to-playhead authored-time conversion when transitions exist (trim/drag R3.1)

## Tests (no count regression; all extend existing suites)
- [x] `EffectsTests` — `replacingLUT` / `removingLUT` / `hasLUT`; LUT display-name cache pruning
- [x] `AudioMasterBusTests` — `AudioGainMapping` unity / round-trip / floor; slider-minimum reachability
- [x] `CaptionsAndKeyframesTests` — `activeWordIndex` gap-hold + empty; `renameCaptionTrack` undo
- [x] `MarkersTests` — next/prev nav + clamp-at-ends + exact-on-marker movement
- [x] `ExportQueueTests` — `retry` requeues cancelled and failed; no-op for non-terminal
- [x] `TransitionsTests` / `TrimAndDragTests` — transition-window authored inverse + snap-through-ripple
- [x] `TransitionsTests` / `TransitionsIntegrationTests` / `PersistenceTests` / `ProjectBundleTests` — directional wipe angle planning + shared video-composition propagation + document/bundle round trips
- [x] `CaptionsAndKeyframesTests` — caption retiming sorts, shifts word timings, and is undoable
- [x] `CaptionsAndKeyframesTests` — skin-smooth keyframe add/update/remove at selected clip playhead + previous/next seek
- [x] `RenderCacheTests` / `CaptionsAndKeyframesTests` — render-cache disk spill/rehydrate/purge + title-raster LRU touch ordering

## Docs
- [x] `docs/keyboard-shortcuts.md` — add marker navigation (⌘⇧[ / ⌘⇧]) and refresh the table

## Review follow-ups (addressed in this PR)
- [x] Gemini — waveform IRE labels sit above their reference lines (no bisecting), top label clamped
- [x] Codex P1 — guard `removePartialOutput()` behind `didBeginEncoding` so a pre-encode cancel can't delete a pre-existing file
- [x] Codex P2 — `replacingLUT` collapses pre-existing stacked LUTs to one slot (+ test)
- [x] Codex P2 — `applyState` purges the caption raster cache on undo/redo of a resolution change (+ tests)
- [x] Codex P2 — LUT display name read from a session cache; no main-actor bookmark resolve in the inspector
- [x] Claude issue comment — retry coverage no longer depends only on queued-cancel semantics
- [x] Claude issue comment — `AudioGainMapping` slider minimum is exactly reachable as silence
- [x] Claude issue comment — marker navigation from exactly on a marker moves to the neighbouring marker
- [x] Claude issue comment — stale LUT display-name cache entries are pruned after replace/remove
- [x] Local macOS validation — `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme "LocalCut Studio" -destination "platform=macOS" -derivedDataPath /private/tmp/LocalCutStudio-DerivedData`

## Follow-up backlog
- [x] Snap-to-playhead authored-time conversion when transitions exist (trim/drag R3.1) — P1
- [x] Directional wipe: stored angle + inspector control + Codable migration (transitions R1.2)
- [ ] Skin-smooth resolution-independent blur radius (needs look decision)
- [x] Keyframe authoring UI for skin-smooth strength (feature-keyframes R6)
- [ ] Keyframable caption style params (phase-30 R2.3)
- [x] Caption line retiming controls + caption timeline lane (caption-tracks R4.1)
- [x] Live audio meter startup (`prepareLive`) (audio-master-bus R5.1)
- [ ] Export-time offline meter animation through the Phase 36 reader/writer PCM path (audio-master-bus R3.3)
- [x] Render-cache + title-raster O(1) LRU; render-cache disk spill (render-cache R2.3)
- [x] Scopes: revision-gated redraw; single-pass histogram; per-pixel vectorscope + colour targets
- [ ] Document model: `ReferenceFileDocument`/Open Recent; async window-close save; staged bundle swap
- [ ] Bundle "Don't copy" import toggle; queue stale-bookmark refresh; `isRunning` TOCTOU
- [ ] Typewriter mask excludes pill; word-range by token index; golden snapshot tests (T3.1 / T5.1)
