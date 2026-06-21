# Requirements: Phase 45 — Program Mode

## R1 — Session

- **R1.1** `ProgramSession` extends Phase 41's `CaptureSession` with a `ProgramCompositor` + `LiveComposeTap` per source.
- **R1.2** Sources can be ScreenCaptureKit display / window / app, `AVCaptureDevice` webcam, mic, or still / title.
- **R1.3** One program session at a time.

## R2 — Compositor

- **R2.1** `ProgramCompositor` reuses the existing Metal compositor pipeline; one `commandBuffer.commit()` per output frame.
- **R2.2** Each source's most recent `CVPixelBuffer` clone stays warm across ticks until replaced or session disposed.
- **R2.3** Scene switches take effect within one compositor tick; no pipeline rebuild; no texture reallocation; no encoder restart.

## R3 — Encoder budget

- **R3.1** Shared `EncoderBudget` actor with consumers `.export`, `.isoRecord`, `.whipPublish`, `.programIso`.
- **R3.2** Default 2 concurrent video sessions on hardware encode; 1 on software-only.
- **R3.3** Budget exhaustion blocks start with `budgetExhausted` error before any encoder opens.
- **R3.4** Record + stream coexistence checks against a single combined budget.

## R4 — Scenes

- **R4.1** `SceneDoc` with `sceneSchemaVersion = 1`; scene definitions persist in `ProjectDoc`.
- **R4.2** Source device bindings persist in app-local settings (NOT `ProjectDoc`).
- **R4.3** Hotkey conflicts are detected and surfaced.
- **R4.4** Optional 200 ms eased transition lerps layer opacity values during the window.

## R5 — Manifest

- **R5.1** `scene-switch` records added to the Phase 41 NDJSON manifest.
- **R5.2** Forward-compatible: parsers skip unknown record kinds.

## R6 — Landing

- **R6.1** Stopping the session lands N ISO tracks + 1 layout track in a single undoable transaction.
- **R6.2** Re-exporting the landed project produces the same composited frames as the live mix.
- **R6.3** Layout track segments store `SceneDefinition` snapshots at boundaries.

## R7 — Recovery

- **R7.1** Killing the app mid-session: Phase 41 recovery surfaces the partial session; layout track reconstructed from the recovered `scene-switch` records.

## R8 — Capability gating

- **R8.1** Requires recording-capable hardware (Phase 41 accelerated tier).
- **R8.2** Sources beyond the encoder budget show a clear "X / N sources active" message.

## R9 — Verification

- **R9.1** Unit test: scene switch updates compositor uniforms within one tick; no pipeline rebuild.
- **R9.2** Mocked-budget test: budget-exhausted before any encoder opens.
- **R9.3** Recovery test on mocked kill mid-session.
- **R9.4** Smoke: 2-cam + 1-screen + mic session with 3 scene switches → ISO + layout track land → re-export matches live mix at sampled times.
- **R9.5** `xcodebuild` (Debug, macOS) green; no test count regression.
