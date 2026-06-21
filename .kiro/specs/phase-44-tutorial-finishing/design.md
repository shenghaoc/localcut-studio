# Design: Phase 44 — Tutorial Finishing

> Status: **Proposed**. Target tag: **v0.1.11**.

## Goal

Four tutorial-finishing tools: (a) silence / dead-air detection over a selected audio track producing a reviewable cut list; (b) keystroke overlay rendered from the Phase 43 event log; (c) timeline markers exported as YouTube chapter text and MP4 chapter metadata; (d) a screencast caption style preset for Phase 30.

## Prerequisites

- Phase 30 (animated captions) for the caption preset.
- Phase 43 (screencast look) for the event-log keystroke source.
- Timeline markers (not yet specced) for chapter export.
- `feature-project-persistence` for bundle round-trip of cut proposals and exported chapter files.

## Approach

1. **Silence detection.** Offline pass on a selected audio track: short-time RMS energy with hysteresis thresholds (open + close). Output is a `[CMTimeRange]` of detected silences and a `[ProposedCut]` list with `(range, suggested action: trim or split)`. Tuning parameters: open threshold (default –40 dBFS), close threshold (default –35 dBFS), minimum silence duration (default 600 ms), padding (default 150 ms).
2. **Review-before-apply.** A modal lists proposed cuts. Per-region apply / skip; full preview by scrubbing. Apply runs as a single undoable transaction.
3. **Keystroke overlay.** A new clip kind sourced from a Phase 43 event log. Renders typed text + modifier-key chips at the bottom of the canvas; configurable font, position, fade-in / out per keystroke.
4. **Chapter export.** Reads timeline markers (`kind: .chapter`) and emits two artefacts:
   - **YouTube chapter text** to a `.txt` sidecar with `MM:SS Title` lines (validated against YouTube's format rules: first chapter at 00:00, ≥3 chapters, monotonic times).
   - **MP4 chapter metadata** via `AVAssetWriter` chapter track on the export. Some container / codec combinations cannot carry chapter tracks — we fall back to the sidecar in that case and surface a note.
5. **Screencast caption preset.** A Phase 30 preset tailored for tutorials (sans-serif, high-contrast fill on dark pill, larger font, no animation). Ships in the built-in preset library.

## Trade-offs

- Hysteresis thresholds (vs. a single threshold) avoid chatter on whisper-quiet ambience.
- AVFoundation chapter tracks vs. sidecar text: AVFoundation supports `AVAssetWriter` chapter tracks for `.mov` / `.mp4` containers. We always write the sidecar (cheap, universally readable) and additionally embed when the container allows.
- Review-before-apply mirrors the Phase 33 (smart reframe) pattern — same UX vocabulary.

## Risks

- Silence detection is sensitive to background noise; the hysteresis defaults are tuned for clean voice recordings and the parameters are exposed.
- VLC / QuickTime / YouTube each honour chapter metadata differently; we document the expected viewer behaviour for each.

## Non-goals

- ASR (Phase 29).
- Filler-word removal (needs ASR).
- LMS / SCORM packaging.
