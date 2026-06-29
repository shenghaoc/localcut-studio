# Bugfix: CMTimeCode Timescale Guard

> Status: **Complete**. Tracked by GitHub issue #23.

Pre-existing document-safety bug raised during the feature-markers review. The
project document stores `CMTime` values as `{ value, timescale }` through
`CMTimeCode`; decoded documents from disk are untrusted input and may be
hand-edited or corrupted.

## Bugs

### B1 - Decoded `CMTimeCode` accepts non-positive timescales

`CMTimeCode.cmTime` constructed `CMTime(value:timescale:)` directly from decoded
fields. A document with `"timescale": 0` or a negative timescale can produce a
non-numeric `CMTime`, and `.seconds` can become `NaN`.

That invalid value can then flow into project-level time surfaces:

- clip source starts, clip durations, and timeline starts;
- media reference durations;
- transition durations;
- keyframe times;
- timeline marker times.

Downstream code commonly converts time to seconds at UI and playback boundaries,
so a `NaN` can reach timeline layout, marker seeking, or CoreMedia comparisons.

- **Fix**: Treat any non-positive stored timescale as corrupt input before
  constructing a `CMTime`: decoded wrappers normalize to zero at the project
  default timescale, and `CMTimeCode.cmTime` defensively returns `.zero` if a
  mutable wrapper ever carries a non-positive timescale. Valid rational values
  still round-trip exactly.
- **Regression**: Decode zero and negative timescales in `PersistenceTests` and
  assert they collapse to `.zero` instead of preserving the corrupt value.
