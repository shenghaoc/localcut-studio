#!/bin/bash
# validate-otio-goldens.sh — Validate golden .otio fixtures with Python opentimelineio.
#
# Usage:
#   ./Scripts/validate-otio-goldens.sh
#
# Requirements:
#   - Python 3.8+
#   - the script creates a local venv when opentimelineio is not already installed
#
# This script is used in CI to validate that golden .otio files parse correctly
# with the reference OpenTimelineIO library. It is NOT required for normal app builds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$PROJECT_ROOT/Tests/Fixtures/Interchange"

# Pin the OTIO version for reproducibility.
OTIO_VERSION="0.17.0"

# Check if fixtures directory exists.
if [ ! -d "$FIXTURES_DIR" ]; then
    echo "ERROR: no fixtures directory at $FIXTURES_DIR."
    exit 1
fi

# Find .otio files.
OTIO_FILES=$(find "$FIXTURES_DIR" -name "*.otio" -type f 2>/dev/null)
if [ -z "$OTIO_FILES" ]; then
    echo "ERROR: no .otio golden files found."
    exit 1
fi

EDL_FILES=$(find "$FIXTURES_DIR" -name "*.edl" -type f 2>/dev/null)
if [ -z "$EDL_FILES" ]; then
    echo "ERROR: no .edl golden files found."
    exit 1
fi

# Check if Python is available.
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" &>/dev/null; then
    echo "WARNING: python3 not found — skipping OTIO validation."
    exit 0
fi

# Install opentimelineio in an isolated environment if not present. CI images can
# use an externally managed Python where system-wide pip installs are rejected.
if ! "$PYTHON_BIN" -c "import opentimelineio" 2>/dev/null; then
    echo "Installing opentimelineio==$OTIO_VERSION..."
    VENV_DIR="${OTIO_VALIDATOR_VENV:-${TMPDIR:-/tmp}/localcut-otio-validator-$OTIO_VERSION}"
    if [ ! -x "$VENV_DIR/bin/python" ]; then
        "$PYTHON_BIN" -m venv "$VENV_DIR"
    fi
    "$VENV_DIR/bin/python" -m pip install --upgrade pip --quiet
    "$VENV_DIR/bin/python" -m pip install "opentimelineio==$OTIO_VERSION" --quiet
    PYTHON_BIN="$VENV_DIR/bin/python"
fi

# Validate each golden file.
ERRORS=0
while IFS= read -r -d '' otio_file; do
    filename=$(basename "$otio_file")
    if "$PYTHON_BIN" -c "
import sys
import opentimelineio as otio
try:
    timeline = otio.adapters.read_from_file('$otio_file')
    print(f'  ✓ $filename — parsed successfully ({len(timeline.tracks)} tracks)')
except Exception as e:
    print(f'  ✗ $filename — PARSE ERROR: {e}', file=sys.stderr)
    sys.exit(1)
"; then
        :
    else
        ERRORS=$((ERRORS + 1))
    fi
done < <(find "$FIXTURES_DIR" -name "*.otio" -type f -print0)

if [ $ERRORS -gt 0 ]; then
    echo "FAILED: $ERRORS golden file(s) failed validation."
    exit 1
fi

echo "All .otio golden files validated successfully."
