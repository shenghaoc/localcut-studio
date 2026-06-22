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

- **Fix**: In `CMTimeCode.cmTime`, fall back to the project default timescale
  `600` whenever the decoded timescale is `<= 0`. Preserve the decoded `value`
  so valid rational values still round-trip exactly and corrupt documents
  degrade predictably.
- **Regression**: Decode zero and negative timescales in `PersistenceTests` and
  assert the resulting `CMTime` is numeric and finite.

