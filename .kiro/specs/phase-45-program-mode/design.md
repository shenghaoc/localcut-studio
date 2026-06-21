# Design: Phase 45 — Program Mode (Live Scenes)

> Status: **Proposed**. Target tag: **v0.1.12**.

## Goal

Drive the existing Metal compositor with live capture sources to produce a switchable-scene program output. Each source is independently ISO-encoded to disk (Phase 41 crash-safe pipeline ×N under one session manifest). Scene switches are hotkey-triggered, take effect within one compositor frame, and are recorded as manifest events. Stopping the session lands a fully re-editable multitrack project: N ISO tracks plus a **layout track** that replays the live mix through the same compositor.

The browser-editor implements this entirely in the pipeline worker via MSTP + WebGPU + N `AVAssetWriter`-equivalent encoders, with a `LiveComposeTap` per source feeding a `ProgramCompositor`. The native port uses ScreenCaptureKit / `AVCaptureSession` + N `AVAssetWriter` + the shared Metal device.

## Prerequisites

- Phase 41 capture engine — `CaptureSession`, per-track pipelines, chunked writer, crash-safe manifest. **Hard dependency.** Phase 45 adds a live-compose tap alongside the ISO path, a `scene-switch` manifest record kind, and a layout track at landing.
- `feature-colour-grading`'s compositor (Metal-backed `EffectCompositor` is the basis for `ProgramCompositor`).
- Keyframes (not yet specced) — layout track segments store transform snapshots as keyframes at boundaries.

## Approach

1. **Session orchestrator.** `ProgramSession` actor extends the Phase 41 session model: acquires `EncoderLease`s up front (or blocks with budget error), creates `TrackPipeline` instances per source (one `AVAssetWriter` each), manages the `ProgramCompositor`, writes `scene-switch` manifest records, and on stop lands the result.
2. **LiveComposeTap.** Per-source bridge from each `TrackPipeline`'s frame reader to the compositor. After cloning each `CVPixelBuffer` (for the encode path), the tap retains the latest clone per source for compositing. Frames stay warm for invisible sources so switching to a scene that reveals a slow-FPS source (screen capture at 5 fps) has a frame available immediately. The previous clone is released only when a newer arrives.
3. **ProgramCompositor.** Wraps the existing Metal compositor with live-source frame management. Holds `Map<sourceId, CVPixelBuffer?>`. On each tick builds the layer list per the current scene's transforms + visibility, samples a `MTLTexture` view of each held buffer (via `CVMetalTextureCache`), and composites — same Metal pipeline the timeline preview uses, single `commandBuffer.commit()` per output frame.
4. **Scene-switch one-frame invariant.** Switching scenes updates only `currentSceneId`. Next tick, `resolveSceneAt(currentSceneId)` returns the new layer set; uniform values change, no pipeline rebuild, no texture reallocation, no encoder restart. The 200 ms eased-transition variant lerps layer opacity values during the window; no extra textures or passes.
5. **Encoder budget.** Shared `EncoderBudget` actor with `acquire(EncoderConsumer)` → `EncoderLease | nil`. Consumers: `.export`, `.isoRecord`, `.whipPublish`, `.programIso`. Default: 2 concurrent video sessions on hardware encode, 1 on software-only. Acquire all video leases up front before any source starts; on partial failure release everything and surface `budgetExhausted`.
6. **Manifest extension.** Phase 41's NDJSON manifest gains `{ kind: "scene-switch", sceneId, atUs }` records. Parsers that don't recognise the kind skip them (forward-compatible).
7. **Scene definitions.** `SceneDoc` with `sceneSchemaVersion`, list of `SceneDefinition { id, name, hotkey, layers }`. Each `SceneLayer { sourceRef, transform, visible, zIndex }`. Scene geometry persists in `ProjectDoc`; device bindings (which physical device backs which `sourceRef`) live in app-local settings. **Forward migration:** mirrors the Phase 30 `CaptionPresetV1` pattern — every read passes through a `migrateSceneDoc(_:)` step that detects the version, applies a chain of `V1→V2→…` upgrades to produce the current shape, and is the single place new schema versions get added. New fields default-fill rather than fail the load; removed fields are ignored on read and dropped on next save.
8. **Layout track landing.** On stop: read `scene-switch` records in order, partition the session into segments, emit a `LayoutClip` per segment with `sceneSnapshot`, place on a new `TimelineTrack { type: .layout }`. Re-export drives the same compositor with the same `SceneDefinition`s — the live mix replays identically.
9. **Cross-application content.** `CALayer` / `CIImage` cannot composite cross-origin web content — we don't have that problem on macOS. Tab capture isn't a thing; ScreenCaptureKit handles displays, windows, and apps natively. The browser's tainted-canvas constraint translates to: cross-app content arrives via ScreenCaptureKit window / app capture only, never via some other route.

## Trade-offs

- Same-process compositor (vs cross-actor) keeps per-frame work cheap; the program compositor IS the preview compositor during a session.
- Layout track stores `SceneDefinition` snapshots at segment boundaries — replays exactly, doesn't depend on the original scenes list still being present.
- Budget is a conservative gate, not a measurement — exceeding real driver limits fails ugly, so we stay below the stated floor.

## Risks

- Sustained 3+ source 1080p record can saturate a single VideoToolbox encoder budget; the probe is conservative and the UI explains the limit.
- Scene-switch one-frame invariant requires the compositor to be one tick per output frame, with the new uniforms picked up immediately. The frame tap discipline (close-exactly-once across replace and dispose) is the safety net.

## Non-goals

- Streaming out (Phase 47).
- Replay buffer (Phase 46).
- Audio mixing beyond Phase 36 buses.
- Virtual camera (impossible without an OS driver).
- Live text editing mid-session (text content fixed at session start).
- Pause / resume within a session (Phase 42 territory; v1 is start / stop).
- Multiple simultaneous program sessions.
