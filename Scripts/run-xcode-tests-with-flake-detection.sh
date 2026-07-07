#!/bin/bash
# run-xcode-tests-with-flake-detection.sh — Run xcodebuild tests with flaky-test detection.
#
# Usage:
#   ./Scripts/run-xcode-tests-with-flake-detection.sh
#
# This wrapper runs xcodebuild test, and on failure:
# 1. Parses the result bundle to identify failed tests
# 2. Retries only the failed tests individually
# 3. Classifies "passed on retry" as flaky
# 4. Emits clear warnings for flaky tests
# 5. Fails CI if deterministic failures remain
#
# Environment variables:
#   PROJECT          — Xcode project path (default: "LocalCut Studio.xcodeproj")
#   SCHEME           — Xcode scheme (default: "LocalCut Studio")
#   RESULT_BUNDLE    — Result bundle path (default: "TestResults.xcresult")
#   DERIVED_DATA     — Derived data path (default: "DerivedData")
#   MAX_RETRIES      — Maximum retry attempts per flaky test (default: 2)
#   FLAKY_THRESHOLD  — Maximum allowed flaky tests before CI fails (default: 5)
#   FLAKY_REPORT     — Path to write flaky test report (default: "flaky-report.json")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Run from the project root so relative paths work regardless of caller cwd.
cd "$PROJECT_DIR"

# Configurable parameters
PROJECT="${PROJECT:-LocalCut Studio.xcodeproj}"
SCHEME="${SCHEME:-LocalCut Studio}"
RESULT_BUNDLE="${RESULT_BUNDLE:-TestResults.xcresult}"
DERIVED_DATA="${DERIVED_DATA:-DerivedData}"
MAX_RETRIES="${MAX_RETRIES:-2}"
FLAKY_THRESHOLD="${FLAKY_THRESHOLD:-5}"
FLAKY_REPORT="${FLAKY_REPORT:-flaky-report.json}"

# Counters
FLAKY_TESTS=0
RETRIED_TESTS=0

# Arrays to track results
declare -a FLAKY_NAMES=()
declare -a DETERMINISTIC_FAILURES=()

echo "=== Flaky-Test Detection Wrapper ==="
echo "Project:       $PROJECT"
echo "Scheme:        $SCHEME"
echo "Max retries:   $MAX_RETRIES"
echo "Flaky threshold: $FLAKY_THRESHOLD"
echo ""

# Clean up previous results
rm -rf "$RESULT_BUNDLE" "$DERIVED_DATA"

# First run: full test suite
echo "--- Running full test suite (attempt 1) ---"
set +e
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee xcodebuild.log
FIRST_RUN_EXIT=$?
set -e

if [ $FIRST_RUN_EXIT -eq 0 ]; then
    echo ""
    echo "=== All tests passed on first run ==="
    PASSED_COUNT=$(grep -ic "Test Case.*passed" xcodebuild.log || echo "0")
    echo "Tests passed: $PASSED_COUNT (no failures detected)"
    exit 0
fi

echo ""
echo "--- First run failed (exit code: $FIRST_RUN_EXIT) ---"
echo "Extracting failed tests from result bundle..."

# Extract failed test identifiers from xcresult bundle
# xcresulttool can dump JSON which we parse for failed tests
FAILED_TEST_IDS=()

if [ -d "$RESULT_BUNDLE" ]; then
    # Use xcresulttool to get test results as JSON
    XCRESULTTOOL_STDERR=$(mktemp)
    set +e
    RESULT_JSON=$(xcrun xcresulttool get test-results summary \
        --path "$RESULT_BUNDLE" \
        --format json 2>"$XCRESULTTOOL_STDERR")
    XCRESULTTOOL_EXIT=$?
    set -e

    if [ $XCRESULTTOOL_EXIT -ne 0 ]; then
        echo "WARNING: xcresulttool failed (exit $XCRESULTTOOL_EXIT), stderr:"
        cat "$XCRESULTTOOL_STDERR" >&2
        echo "Falling back to log parsing..."
        RESULT_JSON="{}"
    fi
    rm -f "$XCRESULTTOOL_STDERR"

    # Parse failed tests from the JSON output.
    # xcresulttool schema v0.1.0: testFailures[].testIdentifierString
    # contains the full "TargetName/testName()" format needed for -only-testing:.
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            FAILED_TEST_IDS+=("$line")
        fi
    done < <(echo "$RESULT_JSON" | python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError) as exc:
    print(f'Warning: could not parse xcresulttool JSON: {exc}', file=sys.stderr)
    sys.exit(0)

# Use testFailures (xcresulttool schema v0.1.0) which provides
# testIdentifierString in 'TargetName/testName()' format.
for failure in data.get('testFailures', []):
    identifier = failure.get('testIdentifierString', '')
    if identifier:
        print(identifier)
" || true)
fi

# If xcresulttool didn't work, try parsing the log output
if [ ${#FAILED_TEST_IDS[@]} -eq 0 ]; then
    echo "Falling back to log parsing for failed tests..."
    while IFS= read -r line; do
        # Extract test identifiers from "Test case 'X/Y()' failed" or
        # "Test Case 'X/Y()' failed" lines (case-insensitive match).
        if [[ "${line,,}" =~ test\ case\ \'([^\']+)\'\ failed ]]; then
            test_id="${BASH_REMATCH[1]}"
            FAILED_TEST_IDS+=("$test_id")
        fi
    done < <(grep -i "Test Case.*failed" xcodebuild.log || true)
fi

if [ ${#FAILED_TEST_IDS[@]} -eq 0 ]; then
    echo "WARNING: Could not extract specific failed tests. Treating all as failures."
    echo "This may indicate a build failure rather than test failures."
    exit 1
fi

echo ""
echo "Found ${#FAILED_TEST_IDS[@]} failed test(s):"
for test_id in "${FAILED_TEST_IDS[@]}"; do
    echo "  - $test_id"
done

# Retry each failed test individually
echo ""
echo "--- Retrying failed tests ---"

for test_id in "${FAILED_TEST_IDS[@]}"; do
    RETRIED_TESTS=$((RETRIED_TESTS + 1))
    PASSED_ON_RETRY=false

    for attempt in $(seq 1 "$MAX_RETRIES"); do
        echo ""
        echo "Retrying: $test_id (attempt $attempt of $MAX_RETRIES)"

        # Create a fresh result bundle for this retry
        RETRY_RESULT="RetryResult-${RETRIED_TESTS}-${attempt}.xcresult"
        rm -rf "$RETRY_RESULT"

        set +e
        xcodebuild test \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration Debug \
            -destination 'platform=macOS' \
            -derivedDataPath "$DERIVED_DATA" \
            -resultBundlePath "$RETRY_RESULT" \
            -only-testing:"$test_id" \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee "retry-${RETRIED_TESTS}-${attempt}.log"
        RETRY_EXIT=$?
        set -e

        # Clean up retry result bundle (before set -e to avoid abort on cleanup)
        rm -rf "$RETRY_RESULT" || true

        if [ $RETRY_EXIT -eq 0 ]; then
            echo "  ✓ PASSED on attempt $attempt — classifying as FLAKY"
            PASSED_ON_RETRY=true
            break
        fi

        echo "  ✗ FAILED on attempt $attempt"
    done

    if [ "$PASSED_ON_RETRY" = true ]; then
        FLAKY_TESTS=$((FLAKY_TESTS + 1))
        FLAKY_NAMES+=("$test_id")
    else
        echo "  ✗ FAILED all $MAX_RETRIES retries — deterministic failure"
        DETERMINISTIC_FAILURES+=("$test_id")
    fi
done

# Generate flaky test report using Python for safe JSON serialization
echo ""
echo "=== Generating flaky test report ==="

# Build newline-separated strings safely (empty arrays produce empty strings).
FLAKY_NAMES_STR=$(printf '%s\n' "${FLAKY_NAMES[@]+"${FLAKY_NAMES[@]}"}")
DETERMINISTIC_NAMES_STR=$(printf '%s\n' "${DETERMINISTIC_FAILURES[@]+"${DETERMINISTIC_FAILURES[@]}"}")

python3 -c "
import json
import sys
from datetime import datetime, timezone

flaky_names = sys.argv[1].split('\n') if sys.argv[1] else []
deterministic_names = sys.argv[2].split('\n') if sys.argv[2] else []
max_retries = int(sys.argv[3])
report_path = sys.argv[4]

report = {
    'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'summary': {
        'total_failed_on_first_run': len(flaky_names) + len(deterministic_names),
        'flaky_passed_on_retry': len(flaky_names),
        'deterministic_failures': len(deterministic_names),
        'max_retries_used': max_retries
    },
    'flaky_tests': [{'name': n, 'passed_on_retry': True} for n in flaky_names if n],
    'deterministic_failures': [{'name': n} for n in deterministic_names if n]
}

with open(report_path, 'w') as f:
    json.dump(report, f, indent=2)
" "$FLAKY_NAMES_STR" \
  "$DETERMINISTIC_NAMES_STR" \
  "$MAX_RETRIES" "$FLAKY_REPORT"

echo "Report written to: $FLAKY_REPORT"

# Print summary
echo ""
echo "=== Test Summary ==="
echo "Failed on first run:    ${#FAILED_TEST_IDS[@]}"
echo "Flaky (passed retry):   $FLAKY_TESTS"
echo "Deterministic failures: ${#DETERMINISTIC_FAILURES[@]}"
echo ""

# Check flaky threshold
if [ $FLAKY_TESTS -gt $FLAKY_THRESHOLD ]; then
    echo "ERROR: Flaky test count ($FLAKY_TESTS) exceeds threshold ($FLAKY_THRESHOLD)"
    echo "Please investigate and quarantine flaky tests or fix the root cause."
    exit 1
fi

# Report flaky tests as warnings
if [ $FLAKY_TESTS -gt 0 ]; then
    echo "WARNING: $FLAKY_TESTS flaky test(s) detected:"
    for name in "${FLAKY_NAMES[@]+"${FLAKY_NAMES[@]}"}"; do
        echo "  ⚠ $name"
    done
    echo ""
    echo "These tests passed on retry but indicate instability."
    echo "Consider investigating the root cause or adding to quarantine list."
fi

# Final exit code
if [ ${#DETERMINISTIC_FAILURES[@]} -gt 0 ]; then
    echo ""
    echo "FAILED: ${#DETERMINISTIC_FAILURES[@]} deterministic test failure(s):"
    for name in "${DETERMINISTIC_FAILURES[@]+"${DETERMINISTIC_FAILURES[@]}"}"; do
        echo "  ✗ $name"
    done
    exit 1
fi

echo ""
echo "=== All failures were flaky (passed on retry) ==="
exit 0
