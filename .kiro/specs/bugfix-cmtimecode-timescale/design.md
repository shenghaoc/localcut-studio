# Design: CMTimeCode Timescale Guard

This is a narrow document-decoding hardening change. It does not add a schema
version, does not change valid encodings, and does not change preview or export
render paths.

## Approach

Centralise the guard in `CMTimeCode.cmTime`:

```swift
var cmTime: CMTime {
    CMTime(value: value, timescale: timescale > 0 ? timescale : 600)
}
```

`CMTimeCode` is the shared rational representation for project-document times,
so this protects every consumer that decodes through the type. The fallback uses
the existing CoreMedia default timescale from the technical steering docs.

## Why the accessor, not decoding

The decoded `{ value, timescale }` pair remains lossless as stored data. Only
the conversion back to `CMTime` normalizes an invalid denominator. Keeping the
raw decoded fields intact avoids inventing a migration step for malformed files
and keeps `Codable` equality / debugging transparent.

## Scope

Protected by this central guard:

- `ClipDoc.sourceStart`, `ClipDoc.duration`, `ClipDoc.timelineStart`;
- `MediaRef.duration`;
- `TransitionDoc.duration`;
- `Keyframe.time`;
- `TimelineMarker.time`.

`CaptionLine` and `WordTiming` already have explicit zero-timescale fallback
logic in their decoders, so this change does not need to touch caption decoding.

## Non-goals

- Rejecting or throwing on malformed project documents. The persistence layer is
  intentionally lenient so users can still open recoverable projects.
- Clamping negative `value` fields. That is a separate semantic question for
  each time field; this bug only concerns invalid denominators.
- Bumping `ProjectDocument.currentSchemaVersion`. The on-disk shape is
  unchanged.

