# Testing Guide

This document describes the testing infrastructure, flaky-test detection, and quarantine policy for LocalCut Studio.

## Test Categories

### 1. LocalCutCore Package Tests (Deterministic)
- **Location:** `Packages/LocalCutCore/Tests/`
- **Framework:** Swift Testing
- **Run command:** `swift test --package-path Packages/LocalCutCore`
- **CI behavior:** No retry. Failures are always deterministic.
- **Characteristics:** Pure logic, no GPU, no media, no network.

### 2. Xcode Unit/Integration Tests
- **Location:** `LocalCut StudioTests/`
- **Framework:** Swift Testing (majority), XCTest (UI tests)
- **Run command:** `xcodebuild test -project "LocalCut Studio.xcodeproj" -scheme "LocalCut Studio"`
- **CI behavior:** Retried via flake-detection wrapper.
- **Categories:**
  - **Editor core:** Undo/redo, trim, transitions, markers
  - **Rendering/preview:** GPU-dependent (Metal, Core Image), serialized
  - **Persistence/export:** Project bundles, render queue
  - **Interchange/OTIO:** Serialization, golden fixtures
  - **Media/audio:** AVFoundation, beat tools
  - **WHIP/publishing:** Network integration, serialized
  - **UI tests:** XCTest-based recorder flow

### 3. OTIO Golden Validation (Deterministic)
- **Location:** `Tests/Fixtures/Interchange/`
- **Run command:** `./Scripts/validate-otio-goldens.sh`
- **CI behavior:** No retry. Failures indicate fixture drift.
- **Characteristics:** Python-based validation of `.otio` and `.edl` files.

### 4. MediaMTX WHIP Integration (Network-dependent)
- **Location:** `LocalCut StudioTests/WhipMediaMTXIntegrationTests.swift`
- **Run command:** `LOCALCUT_REQUIRE_MEDIAMTX_INTEGRATION=1 ./Scripts/run-mediamtx-whip-integration.sh`
- **CI behavior:** Skipped if no container runtime and not required. In CI (where it is required), fails immediately if MediaMTX cannot start within 30 seconds. The wrapper attempts Docker, then Podman, then a direct binary fallback on macOS. No retry logic.
- **Characteristics:** Requires MediaMTX container or binary, network port binding.

## Flaky-Test Detection

### How It Works

CI uses `Scripts/run-xcode-tests-with-flake-detection.sh` to run Xcode tests:

1. **First run:** Full test suite runs normally.
2. **On failure:** Script extracts failed test identifiers from `xcresult` bundle. If `xcresulttool` is unavailable or fails, the script falls back to parsing `xcodebuild.log` for failed test case lines.
3. **Retry:** Each failed test is retried individually (up to `MAX_RETRIES` times).
4. **Classification:**
   - **Flaky:** Test fails on first run but passes on retry.
   - **Deterministic:** Test fails consistently.
5. **Reporting:** Generates `flaky-report.json` with details.
6. **CI outcome:**
   - Deterministic failures → CI fails.
   - Flaky tests only → CI passes with warnings.
   - Flaky count exceeds threshold → CI fails.

### Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_RETRIES` | 2 | Maximum retry attempts per flaky test |
| `FLAKY_THRESHOLD` | 5 | Maximum allowed flaky tests before CI fails |
| `FLAKY_REPORT` | `flaky-report.json` | Path to write flaky test report |

### What Gets Retried

- **Retried:** Individual Xcode test cases that fail on first run.
- **Not retried:**
  - LocalCutCore package tests (deterministic).
  - OTIO golden validation (deterministic).
  - Build failures (not test failures).
  - Tests that fail on all retries (deterministic).

### Interpreting Results

**Flaky report format:**
```json
{
  "timestamp": "2026-07-07T01:00:00Z",
  "summary": {
    "total_failed_on_first_run": 3,
    "flaky_passed_on_retry": 2,
    "deterministic_failures": 1,
    "max_retries_used": 2
  },
  "flaky_tests": [
    {"name": "SuiteName/testName()", "passed_on_retry": true}
  ],
  "deterministic_failures": [
    {"name": "SuiteName/otherTest()"}
  ]
}
```

**CI logs show:**
```
Retrying: SuiteName/testName() (attempt 1 of 2)
  ✓ PASSED on retry — classifying as FLAKY
```

## Quarantine Policy

### What Counts as Flaky

A test is **flaky** if:
1. It fails on the initial CI run.
2. It passes when retried in isolation.
3. The failure is transient (not caused by test ordering or shared state).

A test is **NOT flaky** if:
- It fails consistently on retry (deterministic failure).
- It fails due to build errors.
- It fails because of missing dependencies or configuration.
- FixtureGenerator failures (these stem from a known fixture-isolation problem where tests share mutable fixture state, tracked separately in the fixture-isolation PR).

### Who May Quarantine a Test

- **Repository maintainers** may quarantine tests.
- **Contributors** may propose quarantine in a PR, but require maintainer approval.
- **Automated systems** may NOT automatically quarantine tests.

### Quarantine Process

1. **Prove flakiness:** Run the test at least 10 times locally. A test that fails in fewer than 50% of runs (and passes on subsequent runs) is considered flaky. A test that fails in every run is a deterministic failure and must not be quarantined.
2. **File an issue:** Create a GitHub issue with:
   - Test name and suite
   - Failure frequency (e.g., "fails 2 in 10 runs")
   - Root cause hypothesis (if known)
   - Link to CI failure logs
3. **Add to quarantine list:** Update the table below with:
   - Test name
   - Reason for quarantine
   - Issue number
   - Owner (GitHub username)
   - Date added
   - Maximum quarantine duration (see below)
4. **PR review:** Quarantine changes require review from a maintainer.

### Quarantine List

| Test Name | Reason | Issue | Owner | Date Added | Max Duration |
|-----------|--------|-------|-------|------------|--------------|
| *(none currently quarantined)* | — | — | — | — | — |

### Maximum Quarantine Duration

| Category | Max Duration | Action if Expired |
|----------|--------------|-------------------|
| GPU/Metal-dependent | 30 days | Must fix or remove test |
| Network/Integration | 14 days | Must fix or mock |
| AVFoundation timing | 30 days | Must fix or add tolerance |
| Other transient | 14 days | Must fix or remove |

**If a quarantined test exceeds its maximum duration:**
1. The issue is escalated to the team.
2. The test must be fixed, mocked, or removed.
3. The quarantine cannot be extended without team approval.

### Rules

1. **Deterministic failures must NOT be quarantined.** If a test fails consistently, it's a real bug.
2. **Quarantined tests are still run.** They are flagged as flaky but do not block CI.
3. **Quarantine is temporary.** Every quarantined test must have a fix plan.
4. **No silent skips.** All quarantined tests are visible in the quarantine list above.
5. **FixtureGenerator failures are not quarantined.** These are deterministic fixture-isolation issues that belong to the fixture-isolation PR.
6. **Quarantine list is advisory.** The list is a human-process convention with no automated enforcement. Quarantined tests are not excluded from the flaky count in CI. If a quarantined test causes the flaky threshold to be exceeded, it must be fixed, mocked, or removed.

### Reporting

- **CI artifacts:** `flaky-report.json` is uploaded on every run (30-day retention).
- **Failure artifacts:** `xcodebuild.log`, `TestResults.xcresult`, and `retry-*.log` are uploaded on failure (7-day retention).
- **Monitoring:** Review flaky reports weekly. Escalate if flaky count trends upward.

## Running Tests Locally

### Full test suite
```bash
xcodebuild test \
  -project "LocalCut Studio.xcodeproj" \
  -scheme "LocalCut Studio" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

### With flake detection
```bash
./Scripts/run-xcode-tests-with-flake-detection.sh
```

### Package tests only
```bash
swift test --package-path Packages/LocalCutCore
```

### OTIO golden validation
```bash
./Scripts/validate-otio-goldens.sh
```

### MediaMTX integration (requires Docker/Podman or manual binary)
```bash
LOCALCUT_REQUIRE_MEDIAMTX_INTEGRATION=1 ./Scripts/run-mediamtx-whip-integration.sh
```

## CI Workflow

### Jobs

1. **package-test:** Runs LocalCutCore package tests (deterministic, no retry).
2. **test:** Runs Xcode tests with flake detection, OTIO golden validation, and MediaMTX integration. Depends on `package-test` — it only runs after package tests pass, to fail fast on pure-logic regressions.

### Artifacts

| Artifact | When | Retention |
|----------|------|-----------|
| `xcode-test-diagnostics` | On failure | 7 days |
| `flaky-test-report` | Always | 30 days |

### Concurrency

- CI cancels in-progress runs for the same concurrency group. For PRs, the group is the head branch; for `main` pushes, the group is the branch itself, so a subsequent push to `main` will cancel a prior in-flight `main` run.

## Troubleshooting

### "Flaky test count exceeds threshold"

If CI fails with this message:
1. Review `flaky-report.json` in the artifacts.
2. Check if the flaky tests are known issues.
3. Investigate root cause (GPU timing, network, AVFoundation).
4. Either fix the issue or propose quarantine (with proof).

### "Could not extract specific failed tests"

If the wrapper can't parse failed tests:
1. Check `xcodebuild.log` for build errors.
2. Ensure `xcresulttool` is available (`xcrun xcresulttool`).
3. This may indicate a build failure, not a test failure.

### MediaMTX integration failures

If MediaMTX tests fail:
1. Check if Docker/Podman is running.
2. Check port availability (8889, 9997).
3. Review MediaMTX logs in the failure artifacts.
4. These failures are not retried — the wrapper only retries individual Xcode test cases, not the MediaMTX integration script.
