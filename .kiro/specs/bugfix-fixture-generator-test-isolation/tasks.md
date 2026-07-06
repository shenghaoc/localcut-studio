# Tasks: FixtureGenerator Test Isolation

> Status: **Complete**.

## Implementation

- [x] **B1.1** Gate `writeFixture()` behind `LOCALCUT_REGENERATE_FIXTURES=1` environment variable. In normal mode, `writeFixture()` is a no-op.
- [x] **B1.2** Replace hardcoded `/tmp/localcut-fixtures/` with `NSTemporaryDirectory()` + UUID-based subdirectory in regeneration mode.
- [x] **B1.3** Add `isRegenerationEnabled` static computed property checking the env var.
- [x] **B1.4** Add `outputDirectory` lazy static property that creates the unique temp directory only when regeneration is enabled, and prints the path.
- [x] **B1.5** Update doc comment with regeneration usage instructions.
- [x] **B1.6** Add an active normal-mode regression test that calls `writeFixture()` and verifies it does not create the legacy shared path or any fixture output directory.

## Verification

- [x] **V1** FixtureGenerator suite only: all 9 tests pass (`-only-testing "LocalCut StudioTests/FixtureGenerator"`).
- [x] **V2** Full app test suite: `xcodebuild test` TEST SUCCEEDED.
- [x] **V3** LocalCutCore package tests: `swift test --package-path Packages/LocalCutCore` — 173 tests pass.
- [x] **V4** `git diff --check` — clean.
- [x] **V5** No golden fixtures changed (`git diff -- Tests/Fixtures/` — empty).
- [x] **V6** No tests skipped or assertions weakened.
- [x] **V7** No production code changed.
- [x] **V8** Regeneration mode works: `LOCALCUT_REGENERATE_FIXTURES=1 xcodebuild test -only-testing "LocalCut StudioTests/FixtureGenerator"` writes files to a UUID-based temp directory and prints the path.
- [x] **V9** Review follow-up: normal-mode regression test now exercises the actual write helper rather than only scanning pre-existing temp directories.
- [x] **V10** Review follow-up validation rerun: `xcodebuild test -only-testing:"LocalCut StudioTests/FixtureGenerator"`, `xcodebuild test -skip-testing:"LocalCut StudioUITests"`, `swift test --package-path Packages/LocalCutCore`, `./Scripts/validate-otio-goldens.sh`, and `git diff --check`.
