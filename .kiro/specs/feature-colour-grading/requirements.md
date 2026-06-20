# Requirements: Colour Grading

## R1 — Effect model

- **R1.1** A per-clip, ordered effect chain stored on `Clip` (Codable-ready), default empty (identity).
- **R1.2** v1 effects: exposure, contrast, saturation, temperature/tint (white balance), and a LUT (`.cube`) slot.
- **R1.3** Every parameter has a documented range, a neutral default, and clamps out-of-range input.

## R2 — Shared render path

- **R2.1** Effects render through a custom `AVVideoCompositing` so **preview and export are pixel-identical**.
- **R2.2** The compositor applies each clip's chain to that clip's frame before layer compositing (transform/opacity still honoured).
- **R2.3** No use of `applyingCIFiltersWithHandler:` (it flattens multi-track compositing).

## R3 — UI

- **R3.1** Inspector "Colour" section appears when a clip is selected: sliders for each parameter + LUT import button.
- **R3.2** Adjustments update the preview without dropping playback position; continuous drags are coalesced.
- **R3.3** A reset control returns a clip to identity.

## R4 — Performance & quality

- **R4.1** Preview stays responsive while grading (GPU-backed Core Image / Metal; no main-actor stalls).
- **R4.2** Colour processing happens in a working space appropriate for the source; output matches the project render settings.

## R5 — Verification

- **R5.1** Unit tests for parameter clamping/defaults and chain identity pass-through.
- **R5.2** Smoke test: grade a clip, scrub, export — exported frames match the preview.
