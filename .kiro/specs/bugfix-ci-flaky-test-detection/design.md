# Design: CI Flaky-Test Detection Bugfix

## Approach

### 1. Keep isolated retries as diagnostics

The wrapper still parses `TestResults.xcresult` or `xcodebuild.log` to find the
failed test identifiers from the first full-suite failure. Each failed test is
retried with `-only-testing:` so the report can show which failures pass in
isolation.

### 2. Require full-suite recovery

If every failed test passes in isolation and the flaky count is within the
configured threshold, the wrapper runs the full Xcode suite again before
returning success. This confirmation uses the same project, scheme, destination,
derived data path, per-test timeout settings, and code-signing settings as the
first run.

Passing criteria:

| State | CI result |
| --- | --- |
| First full-suite run passes | Pass |
| Failed tests pass in isolation and full-suite confirmation passes | Pass with flaky warning |
| Failed tests pass in isolation but full-suite confirmation fails | Fail |
| Any failed test fails all isolated retries | Fail |
| Flaky count exceeds threshold | Fail |

### 3. Do not retry runner failures

`xcresulttool` can surface target runner or bootstrap failures through
`testIdentifierString`, but those strings are not accepted by `xcodebuild
-only-testing:`. The wrapper filters parsed failures to retry only identifiers
that look like target/test identifiers. Build, runner, and bootstrap failures
remain immediate CI failures.

### 4. Surface confirmation state

`flaky-report.json` includes these summary fields:

- `suite_confirmation_required`
- `suite_confirmation_passed`
- `suite_confirmation_attempts`

Failure diagnostics upload the suite-confirmation logs alongside the first-run
and isolated-retry logs.

### 5. macOS shell compatibility

The fallback log parser avoids Bash 4-only parameter expansion because GitHub's
macOS shell path can resolve to Apple Bash 3.2. Case-insensitive matching is done
with a portable regular expression instead.

### 6. Preserve Xcode timeout protection

The wrapper exposes `TEST_TIMEOUTS_ENABLED` and
`DEFAULT_TEST_EXECUTION_TIME_ALLOWANCE` so CI keeps Xcode's per-test timeout
guard on the initial suite run, isolated retries, and full-suite confirmation.

### 7. Retry MediaMTX startup only

The MediaMTX WHIP integration harness retries startup/readiness failures before
failing CI. It does not retry the focused WHIP Xcode test after MediaMTX is
ready, so real integration failures still stay red.

## Non-goals

- Automatically quarantining or skipping tests.
- Retrying LocalCutCore package tests or OTIO golden validation.
- Retrying the focused MediaMTX WHIP Xcode test after MediaMTX is ready.
- Replacing Xcode's result bundle parser with a separate test-report format.
