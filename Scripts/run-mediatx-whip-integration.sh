#!/bin/bash
# Runs the MediaMTX WHIP integration test for LocalCut Studio.
#
# Usage: ./Scripts/run-mediatx-whip-integration.sh
#
# Prerequisites: Docker or Podman installed and running.
# Starts MediaMTX in a container, runs the integration test, then stops it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="localcut-mediatx-test"
CONFIG_FILE="${PROJECT_DIR}/Tests/Fixtures/MediaMTX/mediamtx.yml"
IMAGE="bluenviron/mediamtx:latest"

echo "=== MediaMTX WHIP Integration Test ==="

# Check for container runtime
if command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
elif command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
else
    echo "SKIP: No container runtime (docker/podman) found."
    exit 0
fi

# Cleanup function
cleanup() {
    echo "Stopping MediaMTX container..."
    ${CONTAINER_CMD} rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}
trap cleanup EXIT

# Remove any existing container
${CONTAINER_CMD} rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# Start MediaMTX
echo "Starting MediaMTX container..."
${CONTAINER_CMD} run -d \
    --name "${CONTAINER_NAME}" \
    -p 8889:8889 \
    -p 9997:9997 \
    -v "${CONFIG_FILE}:/mediamtx.yml:ro" \
    "${IMAGE}"

# Wait for MediaMTX to be ready
echo "Waiting for MediaMTX to start..."
for i in $(seq 1 30); do
    if curl -s http://localhost:9997/v3/config/get >/dev/null 2>&1; then
        echo "MediaMTX is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: MediaMTX did not start within 30 seconds."
        ${CONTAINER_CMD} logs "${CONTAINER_NAME}" 2>&1 | tail -20
        exit 1
    fi
    sleep 1
done

# Run the integration test via xcodebuild
echo "Running integration test..."
cd "${PROJECT_DIR}"
xcodebuild test \
    -project "LocalCut Studio.xcodeproj" \
    -scheme "LocalCut Studio" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -only-testing:"LocalCut StudioTests/WhipMediaMTXIntegrationTests" \
    2>&1 | tail -30

echo "=== Done ==="
