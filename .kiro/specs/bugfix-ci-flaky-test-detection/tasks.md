# Tasks: CI Flaky-Test Detection Bugfix

> Status: **Implemented**.

## Wrapper behavior

- [x] **T1.1** Keep the first-run Xcode command and failed-test extraction path.
- [x] **T1.2** Retry failed tests individually for diagnostics.
- [x] **T1.3** Require a full-suite confirmation run before CI passes after
  isolated retries.
- [x] **T1.4** Fail CI when isolated retries pass but the full suite still fails,
  treating that as order-dependent/shared-state failure.
- [x] **T1.5** Remove Bash 4-only fallback parsing so the script works under
  Apple Bash 3.2.
- [x] **T1.6** Treat build/test-runner/bootstrap failures as non-retryable instead
  of passing invalid identifiers to `xcodebuild -only-testing:`.
- [x] **T1.7** Preserve Xcode per-test timeout settings across the initial run,
  isolated retries, and full-suite confirmation.
- [x] **T1.8** Retry MediaMTX startup/readiness failures without retrying the
  focused WHIP Xcode test after the service is ready.

## Reporting and docs

- [x] **T2.1** Include full-suite confirmation fields in `flaky-report.json`.
- [x] **T2.2** Upload suite-confirmation logs in CI failure diagnostics.
- [x] **T2.3** Update `docs/TESTING.md` with the confirmation semantics and
  report format.
- [x] **T2.4** Update `AGENTS.md` so the bugfix spec is discoverable.
- [x] **T2.5** Document the timeout environment variables used by the wrapper.
- [x] **T2.6** Document MediaMTX startup retry configuration and diagnostics.

## Verification

- [x] **V1** `git diff --check` passes.
- [x] **V2** `/bin/bash -n Scripts/run-xcode-tests-with-flake-detection.sh`
  passes.
- [x] **V3** Synthetic harness proves isolated retry pass plus full-suite
  confirmation failure exits non-zero.
- [x] **V4** Synthetic harness proves isolated retry pass plus full-suite
  confirmation pass exits zero.
- [x] **V5** Synthetic harness proves non-test runner failures are not retried
  with `-only-testing:`.
- [x] **V6** `swift test --package-path Packages/LocalCutCore` passes.
- [x] **V7** Synthetic harness proves MediaMTX startup/readiness can recover on a
  later attempt before running the focused WHIP Xcode test once.
