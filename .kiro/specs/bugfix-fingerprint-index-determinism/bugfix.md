# Bugfix: FingerprintIndex JSON Determinism

> Status: **Complete**. Closes the gap left by [`feature-project-bundles`](../feature-project-bundles/tasks.md) T2.2.

`feature-project-bundles` T2.2 was marked complete on the strength of a manual
`entries.keys.sorted()` loop inside `FingerprintIndex.encode(to:)`. The intent
was that `FingerprintIndex.encoded()` produce byte-identical JSON for the same
value across saves so `fingerprints.json` could act as a stable diffable /
comparable artifact. Both the design doc (project-bundles `Fingerprints` §) and
the type's own doc comment claim this guarantee. The implementation did not
actually deliver it, and the regression test only flagged the gap by chance.

## Bugs

### B1 — `JSONEncoder` does not preserve `container.encode` order on macOS 26

Swift Foundation's rewritten `JSONEncoder` on macOS 26 does NOT guarantee that
the output byte order of a keyed container matches the order of
`container.encode(_:forKey:)` calls. Without `.sortedKeys` set on
`outputFormatting`, the encoder is free to permute the emitted keys; the length
of the output is stable but the byte sequence is not. The manual
`entries.keys.sorted()` loop in `encode(to:)` therefore only orders the *input*
to the container — the encoder can still reorder on the way out.

CI surfaced this on `ProjectBundleTests.fingerprintIndexCodableRoundTrip` in
[run 27976947992](https://github.com/shenghaoc/localcut-studio/actions/runs/27976947992):
two consecutive `encoded()` calls of the same value both produced 66-byte
outputs that were not byte-equal.

- **Fix**: Set `outputFormatting = [.prettyPrinted, .sortedKeys]` in
  `FingerprintIndex.encoded()`. Keep the manual `entries.keys.sorted()` loop in
  `encode(to:)` — belt and braces. The manual sort guards a future
  container-shape change that the encoder won't auto-sort (e.g. an encoded
  array); `.sortedKeys` guards the macOS 26 keyed-container reordering.
  Neither alone covers every regression path.

### B2 — Round-trip test caught the failure only probabilistically

`fingerprintIndexCodableRoundTrip` asserts byte equality of two consecutive
`encoded()` calls. That assertion is the *right* property to check, but it only
fails when the encoder picks a different permutation between the two calls.
On most runs the two encodes happened to land on the same permutation and the
test went green — which is how `feature-project-bundles` T2.2 was marked
complete in the first place. The test was not wrong, but it was not strong
enough to gate the determinism claim it was supposed to enforce.

- **Disposition**: Out of scope for this bugfix; with `.sortedKeys` set the
  test passes deterministically and serves as a regression for any future
  removal of either guard. A stronger order-position assertion is reserved
  for a follow-up if a determinism regression slips past the current check.

## Why it matters

`ProjectBundle.write` records a SHA-256 per bundled asset into
`fingerprints.json`, then re-uses those digests on the next save's fast path
to skip re-copies when the source still matches. The on-disk
`fingerprints.json` is also the cross-machine artifact for "what was bundled
last time" — diffable in code review, comparable against a committed snapshot
in tests. Non-deterministic output bytes break every byte-level check
downstream of the file: a re-save without changes produces a `fingerprints.json`
that differs from the one already on disk, even when none of the underlying
hex digests changed.
