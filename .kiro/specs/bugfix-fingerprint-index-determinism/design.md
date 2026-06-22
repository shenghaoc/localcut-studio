# Design: FingerprintIndex JSON Determinism

Narrow encoder-hardening change. No on-disk schema bump, no change to the
JSON shape, no change to the fingerprint algorithm or the bundle layout. The
fix moves the determinism guarantee from "manual sort hopes the encoder
preserves call order" to "manual sort *and* encoder-enforced sorted output".

## Approach

```swift
func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
}
```

`encode(to:)` continues to iterate `entries.keys.sorted()` and write through a
`KeyedEncodingContainer<PathKey>`, so the document's top-level shape stays
`{ "assets/<id>.<ext>": "<hex>" }`. The decoded round-trip is unchanged
(`init(from:)` already reads `allKeys` in any order).

## Why both guards

- **Manual `entries.keys.sorted()` in `encode(to:)`** — guarantees a stable
  input order to the encoder. If a future revision of the type swaps the
  container shape to something `JSONEncoder` does not auto-sort (e.g. an
  encoded array of `{ path, digest }` pairs), the manual sort still bounds
  the output to a single canonical order.
- **`.sortedKeys` in `outputFormatting`** — covers macOS 26 Foundation's
  rewritten `JSONEncoder`. It does not guarantee keyed-container output
  preserves the order of `container.encode(...)` calls; setting `.sortedKeys`
  is the documented way to make the output stable.

Either alone leaves a regression path open: the manual sort alone is what the
shipped code did and CI just flaked through; `.sortedKeys` alone would work
for today's `[String: String]` but would silently regress if a future shape
switched to a non-keyed-container path the flag doesn't reach. The code
comment in `ProjectBundle.swift` records both reasons inline.

## Test posture

`ProjectBundleTests.fingerprintIndexCodableRoundTrip` stays unchanged: it
asserts byte equality of two consecutive `encoded()` calls and an
encode→decode round-trip. With `.sortedKeys` set, that assertion holds
deterministically and serves as a regression for any future removal of either
guard. If a determinism regression ever slips past the current check, a
stronger explicit "keys appear in lexicographic order" assertion is the next
step — held out of this fix to keep the change surgical.

## Non-goals

- No `schemaVersion` bump; the JSON shape and contents are unchanged for any
  bundle that already had its keys in sorted order on disk (the common case).
- No change to `FingerprintIndex.entries` or its `Codable` keys.
- No change to the fast-path logic in `ProjectBundle.write` — only its
  underlying determinism contract.
- No backfill of existing bundles. A re-save under the fixed code produces a
  canonical `fingerprints.json`; older non-canonical files decode normally
  and are rewritten in canonical form on the next save.
