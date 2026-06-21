# Requirements: Phase 40 — On-Device Language Tools

## R1 — Availability gating

- **R1.1** Probe `LanguageAvailability.status(from:to:)` (Translation framework) for the requested pair and `SystemLanguageModel.default.availability` (Foundation Models) for the draft pipeline at startup.
- **R1.2** When either is `unavailable`, the entire language-tools surface is hidden (no error, no nag).
- **R1.3** `downloadable` exposes a download button with displayed size; `downloading` shows progress.
- **R1.4** No other feature depends on this phase being available.

## R2 — Translation

- **R2.1** `LanguageDetection` infers source language from the first non-empty caption line; user-overridable.
- **R2.2** Each caption line translates via `TranslationSession.translate(text)`; the output line preserves the source's `CMTimeRange` exactly.
- **R2.3** Output lands as a SECOND `CaptionTrack`; both tracks export as paired SRT/VTT sidecars (`stem.zh.srt`, `stem.en.srt`).

## R3 — Draft

- **R3.1** Foundation Models drafts titles (3), hashtags (5–10), and 文案 (long-form Chinese copy) from the transcript.
- **R3.2** Output is read-only and copy-only; never auto-applied to the project.
- **R3.3** Long transcripts hierarchically summarise under the token cap.

## R4 — Offline

- **R4.1** Once Apple reports the relevant models `ready`, the feature works offline.
- **R4.2** No network calls beyond the OS-managed model download.

## R5 — Privacy

- **R5.1** No telemetry. No logs of caption text or transcript text leave the device.
- **R5.2** Drafted text persists only in the user's clipboard if they copy; it is not stored in `ProjectDoc`.

## R6 — Verification

- **R6.1** Unit tests assert: zero visible UI when probes return `unavailable`.
- **R6.2** Translation round-trip preserves source `CMTimeRange` byte-for-byte.
- **R6.3** Smoke: caption track → translate → second track present → bilingual SRT export.
- **R6.4** `xcodebuild` (Debug, macOS) green; no test count regression.
