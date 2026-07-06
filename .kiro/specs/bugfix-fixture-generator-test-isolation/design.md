# Design: FixtureGenerator Test Isolation

Narrow test-infrastructure fix. No production code changes, no serializer output changes, no golden fixture changes. The fix is confined to `FixtureGenerator.swift` in the test target.

## Approach

Replace the unconditional `/tmp/localcut-fixtures/` write with a two-mode design:

### Normal mode (default)

`writeFixture()` checks `ProcessInfo.processInfo.environment["LOCALCUT_REGENERATE_FIXTURES"]`. When the variable is absent or not `"1"`, the function returns immediately — no directory creation, no file writes. All 9 tests pass as no-ops.

Golden fixture validation is already handled by the separate `GoldenFixtureTests` suite, which compares fresh serializer output against committed fixtures under `Tests/Fixtures/Interchange/`. The generator tests are not needed for validation.

### Regeneration mode

When `LOCALCUT_REGENERATE_FIXTURES=1` is set, a lazily-initialized `static let outputDirectory` creates a unique subdirectory:

```swift
let base = NSTemporaryDirectory()
let dir = (base as NSString).appendingPathComponent("localcut-fixtures-\(UUID().uuidString)")
```

The UUID suffix ensures:
- Parallel regeneration runs don't collide
- Multiple developers on the same machine don't overwrite each other
- The path is stable within a single test run (all 9 tests write to the same directory)

The output path is printed once at suite start via the lazy initializer's `print()`.

## Why both modes

- **Normal mode** — the 9 tests exercise the serializer code paths (OTIO and EDL) even in no-op mode. The serializer calls still execute; only the file write is skipped. Tests pass in CI, local full-suite runs, and individual runs.
- **Regeneration mode** — developers who modify the serializer and need to refresh golden fixtures set the env var and collect files from the printed temp path, then copy to `Tests/Fixtures/Interchange/`.

## Non-goals

- No change to golden fixture contents
- No change to serializer output
- No change to `GoldenFixtureTests`
- No change to `Scripts/validate-otio-goldens.sh`
- No change to production code
