#!/bin/bash
# validate-otio-goldens.sh — Validate golden .otio fixtures with Python opentimelineio.
#
# Usage:
#   ./Scripts/validate-otio-goldens.sh
#
# Requirements:
#   - Python 3.8+
#   - pip install opentimelineio==0.17.0
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
if ! command -v python3 &>/dev/null; then
    echo "WARNING: python3 not found — skipping OTIO validation."
    echo "To run locally: pip3 install opentimelineio==$OTIO_VERSION"
    exit 0
fi

# Install opentimelineio if not present.
if ! python3 -c "import opentimelineio" 2>/dev/null; then
    echo "Installing opentimelineio==$OTIO_VERSION..."
    pip3 install "opentimelineio==$OTIO_VERSION" --quiet
fi

# Validate each golden file.
ERRORS=0
while IFS= read -r -d '' otio_file; do
    filename=$(basename "$otio_file")
    if python3 -c "
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
