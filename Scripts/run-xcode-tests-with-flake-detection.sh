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
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
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
    # Count tests from log
    TOTAL_TESTS=$(grep -c "Test case.*passed" xcodebuild.log || echo "0")
    echo "Total tests passed: $TOTAL_TESTS"
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
    RESULT_JSON=$(xcrun xcresulttool get test-results summary \
        --path "$RESULT_BUNDLE" \
        --format json 2>/dev/null || echo "{}")

    # Parse failed tests from the JSON output
    # The structure is: testNodes[].children[].name, testNodes[].children[].testStatus
    # We need to extract "SuiteName/TestName" format for -only-testing:
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            FAILED_TEST_IDS+=("$line")
        fi
    done < <(echo "$RESULT_JSON" | python3 -c "
import json
import sys

try:
    data = json.load(sys.stdin)
except:
    sys.exit(0)

def extract_failed_tests(node, prefix=''):
    results = []
    name = node.get('name', '')
    status = node.get('testStatus', '')

    if status == 'Failure':
        # Build the full test identifier
        if prefix:
            full_id = f'{prefix}/{name}'
        else:
            full_id = name
        results.append(full_id)

    # Recurse into children
    for child in node.get('children', []):
        child_prefix = f'{prefix}/{name}' if prefix else name
        results.extend(extract_failed_tests(child, child_prefix))

    return results

# Navigate to test nodes
test_nodes = data.get('testNodes', [])
for node in test_nodes:
    failed = extract_failed_tests(node)
    for f in failed:
        print(f)
" 2>/dev/null || true)
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
    done < <(grep -i "Test [Cc]ase.*failed" xcodebuild.log || true)
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

        # Clean up retry result bundle
        rm -rf "$RETRY_RESULT"

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
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
done

# Generate flaky test report
echo ""
echo "=== Generating flaky test report ==="

cat > "$FLAKY_REPORT" << EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "summary": {
    "total_failed_on_first_run": ${#FAILED_TEST_IDS[@]},
    "flaky_passed_on_retry": $FLAKY_TESTS,
    "deterministic_failures": $FAILED_TESTS,
    "max_retries_used": $MAX_RETRIES
  },
  "flaky_tests": [
EOF

# Add flaky test entries
for i in "${!FLAKY_NAMES[@]}"; do
    name="${FLAKY_NAMES[$i]}"
    if [ $i -lt $(( ${#FLAKY_NAMES[@]} - 1 )) ]; then
        echo "    {\"name\": \"$name\", \"passed_on_retry\": true}," >> "$FLAKY_REPORT"
    else
        echo "    {\"name\": \"$name\", \"passed_on_retry\": true}" >> "$FLAKY_REPORT"
    fi
done

cat >> "$FLAKY_REPORT" << EOF
  ],
  "deterministic_failures": [
EOF

# Add deterministic failure entries
for i in "${!DETERMINISTIC_FAILURES[@]}"; do
    name="${DETERMINISTIC_FAILURES[$i]}"
    if [ $i -lt $(( ${#DETERMINISTIC_FAILURES[@]} - 1 )) ]; then
        echo "    {\"name\": \"$name\"}," >> "$FLAKY_REPORT"
    else
        echo "    {\"name\": \"$name\"}" >> "$FLAKY_REPORT"
    fi
done

cat >> "$FLAKY_REPORT" << EOF
  ]
}
EOF

echo "Report written to: $FLAKY_REPORT"

# Print summary
echo ""
echo "=== Test Summary ==="
echo "Failed on first run:    ${#FAILED_TEST_IDS[@]}"
echo "Flaky (passed retry):   $FLAKY_TESTS"
echo "Deterministic failures: $FAILED_TESTS"
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
    for name in "${FLAKY_NAMES[@]}"; do
        echo "  ⚠ $name"
    done
    echo ""
    echo "These tests passed on retry but indicate instability."
    echo "Consider investigating the root cause or adding to quarantine list."
fi

# Final exit code
if [ $FAILED_TESTS -gt 0 ]; then
    echo ""
    echo "FAILED: $FAILED_TESTS deterministic test failure(s):"
    for name in "${DETERMINISTIC_FAILURES[@]}"; do
        echo "  ✗ $name"
    done
    exit 1
fi

echo ""
echo "=== All failures were flaky (passed on retry) ==="
exit 0
