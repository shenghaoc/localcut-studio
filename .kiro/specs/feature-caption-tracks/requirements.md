# Requirements: Caption Tracks

## R1 — Model

- **R1.1** A project holds zero or more `CaptionTrack`s alongside its video and audio tracks; tracks are independently mute-able.
- **R1.2** `CaptionLine` has `id: UUID`, `range: CMTimeRange`, `text: String`, `words: [WordTiming]?`.
- **R1.3** `WordTiming` has `range: CMTimeRange`, `word: String`.
- **R1.4** Track `lines` are stored sorted by `range.start`; mutation paths keep this invariant.
- **R1.5** `Project.duration` includes the latest caption-line end across all caption tracks.

## R2 — Sidecar import

- **R2.1** SRT importer parses `hh:mm:ss,mmm --> hh:mm:ss,mmm` timestamps and the multi-line text payload that follows; cue numbering lines are accepted and ignored.
- **R2.2** VTT importer parses `[hh:]mm:ss.mmm --> [hh:]mm:ss.mmm` timestamps; the `WEBVTT` header is required and consumed; `STYLE`, `NOTE`, `REGION` blocks are skipped.
- **R2.3** Both importers operate on UTF-8 input. Non-UTF-8 input surfaces a user-visible error; partial parses are not produced.
- **R2.4** A malformed cue is dropped (logged once at debug); the importer advances to the next blank line and continues.
- **R2.5** The importer returns a `CaptionTrack` with `words = nil` on every line. ASR alignment is out of scope here.
- **R2.6** Importing into an existing project creates a new track; the user can rename it. Two import calls do not merge.

## R3 — Persistence

- **R3.1** `ProjectDocument` round-trips caption tracks, lines, and word timings losslessly via `CMTimeCode` for every `CMTime`.
- **R3.2** Older documents without `captionTracks` decode to an empty list.
- **R3.3** Documents with extra/unknown keys still decode (matches the existing lenient pattern).

## R4 — Editing

- **R4.1** Adding, deleting, re-ordering, retiming, and renaming caption lines / tracks flows through `EditorModel` so undo / redo work.
- **R4.2** Edits that violate the sorted invariant (e.g. moving a line earlier) re-sort the track and update derived `Project.duration` accordingly.

## R5 — Verification

- **R5.1** Unit tests for SRT parsing: well-formed multi-line cue, escaped `,` decimal, missing trailing newline, malformed block in the middle, CRLF line endings.
- **R5.2** Unit tests for VTT parsing: WEBVTT header presence, `NOTE`/`STYLE` block skipping, optional `hh:` prefix.
- **R5.3** Codable round-trip preserves lines and word timings exactly.
- **R5.4** `Project.duration` reflects caption-track end times.
- **R5.5** `xcodebuild` (Debug, macOS) green; no test count regression.
