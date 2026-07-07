# Design: FixtureGenerator Test Isolation

Narrow test-infrastructure fix. No production code changes, no serializer output changes, no golden fixture changes. The fix is confined to `FixtureGenerator.swift` in the test target.

## Approach

Replace the unconditional `/tmp/localcut-fixtures/` write with a two-mode design:

### Normal mode (default)

In normal mode, the lazily-initialized `outputDirectory` is `nil` because neither the `LOCALCUT_REGENERATE_FIXTURES` Swift compilation condition nor a propagated runtime `LOCALCUT_REGENERATE_FIXTURES=1` environment variable is present. `writeFixture()` checks `Self.outputDirectory` with a guard-let and returns immediately when it's `nil` — no directory creation, no file writes. The generator tests pass as no-ops, though the serializer code paths (OTIO and EDL) are still exercised; only the disk write is skipped.

Golden fixture validation is already handled by the separate `GoldenFixtureTests` suite, which compares fresh serializer output against committed fixtures under `Tests/Fixtures/Interchange/`. The generator tests are not needed for validation.

### Regeneration mode

When the `LOCALCUT_REGENERATE_FIXTURES` Swift compilation condition is passed through `OTHER_SWIFT_FLAGS` (or a runtime `LOCALCUT_REGENERATE_FIXTURES=1` environment variable reaches the test host), a lazily-initialized `static let outputDirectory` creates a unique subdirectory:

```swift
let base = NSTemporaryDirectory()
let dir = (base as NSString).appendingPathComponent("localcut-fixtures-\(UUID().uuidString)")
```

The UUID suffix ensures:
- Parallel regeneration runs don't collide
- Multiple developers on the same machine don't overwrite each other
- The path is stable within a single test run (all generator cases write to the same directory)

The lazy initializer still logs the output path for local diagnostics, but Xcode
can suppress that output for passing Swift Testing suites. The regeneration
sentinel test verifies the path directly, and app-hosted runs write under the
LocalCut Studio app container temp directory:

```text
~/Library/Containers/com.shenghaoc.LocalCutStudio/Data/tmp/localcut-fixtures-<UUID>
```

## Why both modes

- **Normal mode** — the generator cases exercise the serializer code paths (OTIO and EDL) even in no-op mode. The serializer calls still execute; only the file write is skipped. Tests pass in CI, local full-suite runs, and individual runs.
- **Regeneration mode** — developers who modify the serializer and need to refresh golden fixtures pass the Swift compilation condition and collect files from the UUID-scoped temp path, then copy to `Tests/Fixtures/Interchange/`.

## Regression coverage

The normal-mode isolation test calls `writeFixture()` directly with a UUID-named
sentinel fixture. It snapshots `NSTemporaryDirectory()` before and after the
call, then verifies:

- `outputDirectory` stays `nil`
- no sentinel file appears under the old shared `localcut-fixtures` path
- no new `localcut-fixtures*` output directory is created

The test returns early when regeneration is enabled, because regeneration mode
is intentionally allowed to write fixture files. A separate regeneration-mode
sentinel test returns early in normal mode, then verifies that `outputDirectory`
uses a UUID-scoped `localcut-fixtures-*` directory and that `writeFixture()`
actually writes a sentinel file when regeneration is enabled.

## Non-goals

- No change to golden fixture contents
- No change to serializer output
- No change to `GoldenFixtureTests`
- No change to `Scripts/validate-otio-goldens.sh`
- No change to production code
