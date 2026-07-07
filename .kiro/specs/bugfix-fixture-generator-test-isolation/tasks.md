# Tasks: FixtureGenerator Test Isolation

> Status: **Complete**.

## Implementation

- [x] **B1.1** Gate `writeFixture()` behind the `LOCALCUT_REGENERATE_FIXTURES` Swift compilation condition for xcodebuild CLI regeneration, while still accepting runtime `LOCALCUT_REGENERATE_FIXTURES=1` when a runner propagates it. In normal mode, `writeFixture()` is a no-op.
- [x] **B1.2** Replace hardcoded `/tmp/localcut-fixtures/` with `NSTemporaryDirectory()` + UUID-based subdirectory in regeneration mode.
- [x] **B1.3** Add `isRegenerationEnabled` static computed property checking the compile condition and compatible runtime env var.
- [x] **B1.4** Add `outputDirectory` lazy static property that creates the unique temp directory only when regeneration is enabled.
- [x] **B1.5** Update doc comment with regeneration usage instructions.
- [x] **B1.6** Add an active normal-mode regression test that calls `writeFixture()` and verifies it does not create the legacy shared path or any fixture output directory.
- [x] **B1.7** Add a regeneration-mode sentinel test that verifies `writeFixture()` writes into the UUID-scoped output directory when regeneration is enabled.

## Verification

- [x] **V1** FixtureGenerator suite only: the original generator cases plus normal-mode and regeneration-mode regression tests pass (`-only-testing "LocalCut StudioTests/FixtureGenerator"`).
- [x] **V2** Full app test suite: `xcodebuild test` TEST SUCCEEDED.
- [x] **V3** LocalCutCore package tests: `swift test --package-path Packages/LocalCutCore` — 173 tests pass.
- [x] **V4** `git diff --check` — clean.
- [x] **V5** No golden fixtures changed (`git diff -- Tests/Fixtures/` — empty).
- [x] **V6** No tests skipped or assertions weakened.
- [x] **V7** No production code changed.
- [x] **V8** Regeneration mode works: `xcodebuild test -only-testing:"LocalCut StudioTests/FixtureGenerator" OTHER_SWIFT_FLAGS='$(inherited) -D LOCALCUT_REGENERATE_FIXTURES'` writes files to a UUID-based temp directory under the app host container temp root.
- [x] **V9** Review follow-up: normal-mode regression test now exercises the actual write helper rather than only scanning pre-existing temp directories.
- [x] **V10** Review follow-up validation rerun: `xcodebuild test -only-testing:"LocalCut StudioTests/FixtureGenerator"`, `xcodebuild test -skip-testing:"LocalCut StudioUITests"`, `swift test --package-path Packages/LocalCutCore`, `./Scripts/validate-otio-goldens.sh`, and `git diff --check`.
