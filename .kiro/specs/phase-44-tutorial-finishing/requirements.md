# Requirements: Phase 44 — Tutorial Finishing

## R1 — Silence detection

- **R1.1** Offline RMS-with-hysteresis pass on the selected audio track; produces a `[ProposedCut]` list.
- **R1.2** Tunable parameters: open threshold, close threshold, minimum silence duration, padding.
- **R1.3** Output is deterministic on fixtures.

## R2 — Review-before-apply

- **R2.1** Modal lists each proposed cut with per-region apply / skip and a scrubbable preview.
- **R2.2** Apply runs as one undoable transaction.
- **R2.3** Cancelling the modal leaves the project unchanged.

## R3 — Keystroke overlay

- **R3.1** New clip kind sourced from a Phase 43 event log.
- **R3.2** Configurable font, position, per-keystroke fade-in / out durations.
- **R3.3** Modifier-key chips render distinctly from character keys.

## R4 — Chapter export

- **R4.1** YouTube chapter text `.txt` sidecar validated against YouTube's format rules (first chapter at 00:00, ≥3 chapters, monotonic times, each chapter span ≥ 10 s). Sub-10-second spans are rejected with a clear error; the export dialog offers merge / drop options.
- **R4.2** MP4 chapter track embedded when container + codec support it; sidecar always written.
- **R4.3** A documented manual verification step confirms VLC shows the embedded chapters.

## R5 — Screencast caption preset

- **R5.1** A built-in Phase 30 preset tuned for tutorials ships in the preset library.

## R6 — Verification

- **R6.1** Silence detection determinism test on fixtures.
- **R6.2** Chapter sidecar passes a YouTube-rules linter in CI.
- **R6.3** Smoke: detect silences → review → apply → undo → re-apply; markers → export → both artefacts present.
- **R6.4** `xcodebuild` (Debug, macOS) green; no test count regression.
