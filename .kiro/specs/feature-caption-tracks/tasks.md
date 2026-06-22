# Tasks: Caption Tracks

> Status: **Implemented**. Ships with Phase 30.

## Model

- [x] **T1.1** Add `WordTiming`, `CaptionLine`, and `CaptionTrack` to `Models.swift` per the [design](./design.md#model).
- [x] **T1.2** Extend `Project` with `captionTracks: [CaptionTrack]`; widen `duration` to include caption ends.

## Import

- [x] **T2.1** SRT importer parsing cue blocks → `[CaptionLine]`; CRLF normalisation; malformed-block skip.
- [x] **T2.2** VTT importer parsing cue blocks; skip `NOTE`/`STYLE`/`REGION`; `WEBVTT` header guard.
- [x] **T2.3** Surface a typed error on non-UTF-8 input; the editor open path shows it.

## Persistence

- [x] **T3.1** Reuse `CMTimeCode` and inline `CMTimeRange` start/duration encoding in `CaptionLine` / `WordTiming` Codable for symmetry with the rest of the document model.
- [x] **T3.2** Add `CaptionTrackDoc` to `ProjectDocument`; lenient decoding; round-trip via the existing `Project ↔ ProjectDocument` conversions.

## Editing

- [x] **T4.1** Editor commands for add/delete/rename track and add/delete/retime line, undoable through the existing command stack (`EditorModel+Captions.swift`).

## Verification

- [x] **T5.1** Unit tests for SRT and VTT importers covering R5.1 and R5.2.
- [x] **T5.2** Unit tests for `ProjectDocument` round-trip with caption tracks.
- [x] **T5.3** Unit tests for `Project.duration` with caption-only tail.
- [x] **T5.4** `xcodebuild` (Debug, macOS) green; no test count regression.
