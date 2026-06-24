# Design: Caption Tracks (P22 native equivalent)

> Status: **Implemented**. Infrastructure prerequisite for Phase 30 (animated captions) and Phase 44 (tutorial finishing).

## Goal

Give the project model a first-class **caption track** alongside its video and audio tracks: an ordered list of timestamped lines with optional per-word timings, importable from SRT and VTT sidecars and persisted in the `.lcstudio` document. This spec is the data layer only — rendering, styling, and animation live in [`phase-30-animated-captions`](../phase-30-animated-captions/), and ASR-generated word timings come from [`phase-29-auto-captions`](../phase-29-auto-captions/) on macOS 27.

## Model

```swift
struct WordTiming: Hashable, Codable {
    var range: CMTimeRange
    var word: String
}

struct CaptionLine: Identifiable, Hashable, Codable {
    let id: UUID
    var range: CMTimeRange     // start + duration in the project's timeline space
    var text: String           // the rendered line; CRLF / NEL collapsed to LF on import
    var words: [WordTiming]?   // nil ⇒ full-line rendering only (no karaoke highlight)
}

@Observable
final class CaptionTrack: Identifiable {
    let id: UUID
    var name: String
    var isMuted: Bool          // hides the track from preview and export
    var lines: [CaptionLine]   // sorted by line.range.start; the editor maintains the order
}
```

The runtime `CaptionTrack` is reference-typed (`@Observable`) to match `Track`'s shape so the inspector can bind to a single track instance. Lines themselves are value types so undo can snapshot them cheaply.

The `Project` gains:

```swift
var captionTracks: [CaptionTrack] = []
```

`Project.duration` widens to include caption tracks so a final caption past the last clip still extends the playable timeline.

## Sidecar import

Both SRT and VTT are line-oriented cue formats. The importer:

1. Reads the file as UTF-8 (falls back to `String.Encoding.utf8` only — files in legacy encodings are out of scope and surface a user-visible error in the open dialog).
2. Normalises line endings to LF.
3. Splits the file into cue blocks on blank lines.
4. Parses each block's timestamp line — accepting `hh:mm:ss,mmm --> hh:mm:ss,mmm` (SRT) and `hh:mm:ss.mmm --> hh:mm:ss.mmm` (VTT, optional `hh:`).
5. Builds a `CaptionLine` per cue, with `words = nil`; ill-formed cues are skipped (logged once, never crash).
6. Drops the VTT `WEBVTT` header and any `STYLE`/`NOTE`/`REGION` blocks — Phase 30 styles are project-level, not sidecar-supplied.

Word-level timings, when ASR comes online in Phase 29, populate `words` post-import via a separate aligner pass; this spec only defines the storage.

## Persistence

`ProjectDocument` grows a `captionTracks: [CaptionTrackDoc]` field. `CaptionTrackDoc` mirrors the runtime track with a Codable `CaptionLineDoc { id, range: CMTimeRangeCode, text, words }` and a Codable `WordTimingDoc`. `CMTimeRangeCode` reuses the `CMTimeCode` rational shape already in the document for `start` + `duration`. Lenient decoding (missing field → empty) keeps older documents openable. `feature-project-persistence`'s schema-version field carries the additions.

Undo/redo flows through the existing `EditorModel+Commands` machinery: every mutation that touches a caption track snapshots the affected track value, the same way clip edits are tracked.

## Trade-offs

- **One caption track type for everything** vs. separate SRT/VTT subtypes: keep one — the difference is on disk, not in the editor.
- **Words on the line, not a parallel array**: a line without words shouldn't pay a memory cost; an optional `words: [WordTiming]?` is clearer than a sentinel.
- **Track is `@Observable` class, lines are values**: matches the existing `Track` / `Clip` pattern so the inspector code can reuse the same binding shape; undo snapshots stay cheap because lines are values.
- **No styling here**: leaving `CaptionStyle` to Phase 30 means this spec lands without dragging in Core Text rendering decisions. The two compose cleanly.

## Risks

- Mojibake-rich SRTs (non-UTF-8) are common; surface a clear error instead of falling through to garbled text. A future spec can add explicit encoding selection.
- A malformed cue mid-file shouldn't drop later cues; the parser advances to the next blank line on any block-level failure.
- VTT styling cues exist in the wild; silently ignoring them is fine — Phase 30 reapplies styling project-side.

## Non-goals

- Caption *styling* (Phase 30).
- ASR word timings (Phase 29).
- Subtitle export styling (Phase 30 burn-in handles styling; sidecar export stays plain text).
- TTML / iTT / EBU-STL importers.
- Speaker labels, position metadata, region layout, RTL bidi tables (deferred).
