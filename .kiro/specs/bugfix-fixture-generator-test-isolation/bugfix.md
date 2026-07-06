# Bugfix: FixtureGenerator Test Isolation

> Status: **Complete**. Fixes the 9 failing FixtureGenerator tests found by the v0.2 stabilization audit.

The `FixtureGenerator` test suite writes generated OTIO/EDL fixture files to `/tmp/localcut-fixtures/` for manual developer collection. All 9 tests share this hardcoded path. When the full test suite runs, the tests fail instantly; they pass individually with `-only-testing`. CI is green because committed golden fixtures under `Tests/Fixtures/Interchange/` are validated by the separate `GoldenFixtureTests` suite, which does not depend on the generator.

## Bugs

### B1 — Shared fixed output path causes test isolation failure

All 9 `FixtureGenerator` tests call `writeFixture(_ name:content:)` which writes to the hardcoded path `/tmp/localcut-fixtures/`. When the full test suite runs:

1. **Parallel execution conflicts** — multiple tests write to the same directory simultaneously.
2. **Sandbox restrictions** — the `/tmp` path may be inaccessible or behave differently under the full test runner sandbox vs. individual test execution via `-only-testing`.
3. **No isolation** — all tests share the same fixed output directory with no per-test cleanup.

The tests pass individually because the test runner has different sandbox/permission context when invoked with `-only-testing`, but fail as a suite due to these isolation issues.

- **Fix**: Gate fixture file writing behind the `LOCALCUT_REGENERATE_FIXTURES=1` environment variable. In normal test mode, `writeFixture()` is a no-op — tests pass without writing anything. In regeneration mode, use `NSTemporaryDirectory()` with a UUID-based subdirectory to avoid collisions between parallel runs. The regression test now calls `writeFixture()` with a UUID sentinel in normal mode and verifies it does not create the old shared path or any new fixture output directory.

### B2 — Regeneration mode uses shared directory without collision protection

When developers explicitly regenerate fixtures, the old code wrote to `/tmp/localcut-fixtures/` — the same path every time. Multiple regeneration runs (or parallel test workers) would overwrite each other's output.

- **Fix**: In regeneration mode, create a unique subdirectory under `NSTemporaryDirectory()` using `localcut-fixtures-<UUID>` naming. The path is printed at suite start so developers know where to collect the files.

## Why it matters

FixtureGenerator tests failing in the full suite produces noise in local development and blocks the v0.2 stabilization gate. The golden fixture validation (GoldenFixtureTests) is unaffected — it reads committed fixtures and does not depend on the generator. But the generator tests are still valuable for developers who need to regenerate fixtures after serializer changes, and they should pass cleanly in all execution modes.
