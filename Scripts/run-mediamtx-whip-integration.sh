#!/bin/bash
# Runs the MediaMTX WHIP integration test for LocalCut Studio.
#
# Usage: ./Scripts/run-mediamtx-whip-integration.sh
#
# Starts MediaMTX in a container when Docker/Podman is available. In required
# environments such as CI, falls back to a pinned MediaMTX release binary on
# macOS so GitHub-hosted macOS runners can execute the test without Docker.
#
# Environment variables:
#   MEDIAMTX_STARTUP_ATTEMPTS      — Startup/readiness attempts before failing (default: 2)
#   MEDIAMTX_READY_TIMEOUT_SECONDS — Seconds to wait for readiness per attempt (default: 30)
#   MEDIAMTX_RETRY_DELAY_SECONDS   — Delay between startup attempts (default: 2)
#   XCODEBUILD_BIN                 — xcodebuild executable override for local harnesses (default: "xcodebuild")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="localcut-mediamtx-test"
CONFIG_FILE="${PROJECT_DIR}/Tests/Fixtures/MediaMTX/mediamtx.yml"
IMAGE="bluenviron/mediamtx:latest"
MEDIAMTX_VERSION="1.19.2"
MEDIAMTX_RELEASE_BASE="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}"
MEDIAMTX_DOWNLOAD_DIR="${PROJECT_DIR}/.build/mediamtx"
MEDIAMTX_LOG="${MEDIAMTX_DOWNLOAD_DIR}/mediamtx.log"
MEDIAMTX_PID=""
CONTAINER_CMD=""
MEDIAMTX_STARTUP_ATTEMPTS="${MEDIAMTX_STARTUP_ATTEMPTS:-2}"
MEDIAMTX_READY_TIMEOUT_SECONDS="${MEDIAMTX_READY_TIMEOUT_SECONDS:-30}"
MEDIAMTX_RETRY_DELAY_SECONDS="${MEDIAMTX_RETRY_DELAY_SECONDS:-2}"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-xcodebuild}"

echo "=== MediaMTX WHIP Integration Test ==="

integration_required() {
    [ "${CI:-}" = "true" ] || [ "${LOCALCUT_REQUIRE_MEDIAMTX_INTEGRATION:-0}" = "1" ]
}

detect_release_asset() {
    local os_name
    local arch_name
    os_name="$(uname -s)"
    arch_name="$(uname -m)"

    case "${os_name}:${arch_name}" in
        Darwin:arm64)
            MEDIAMTX_ASSET="mediamtx_v${MEDIAMTX_VERSION}_darwin_arm64.tar.gz"
            MEDIAMTX_SHA256="c225e46ab65295f95ee9fcda75703129c07add8852483abda09299a78524391f"
            ;;
        Darwin:x86_64)
            MEDIAMTX_ASSET="mediamtx_v${MEDIAMTX_VERSION}_darwin_amd64.tar.gz"
            MEDIAMTX_SHA256="b8851bf53d1e0d6d078240d54e78517a3a239b40040b22cddddf5a0ef2712c17"
            ;;
        *)
            echo "ERROR: No direct MediaMTX fallback is configured for ${os_name}/${arch_name}."
            echo "Install Docker or Podman, or add the platform asset/checksum to this script."
            exit 1
            ;;
    esac
}

ensure_mediamtx_binary() {
    detect_release_asset
    mkdir -p "${MEDIAMTX_DOWNLOAD_DIR}"

    local binary="${MEDIAMTX_DOWNLOAD_DIR}/mediamtx"
    if [ -x "${binary}" ]; then
        echo "Using cached MediaMTX binary: ${binary}"
        MEDIAMTX_BIN="${binary}"
        return
    fi

    local archive="${MEDIAMTX_DOWNLOAD_DIR}/${MEDIAMTX_ASSET}"
    local url="${MEDIAMTX_RELEASE_BASE}/${MEDIAMTX_ASSET}"

    if [ ! -f "${archive}" ]; then
        echo "Downloading MediaMTX ${MEDIAMTX_VERSION} (${MEDIAMTX_ASSET})..."
        curl -L --fail -o "${archive}" "${url}"
    else
        echo "Using cached MediaMTX archive: ${archive}"
    fi

    echo "Verifying MediaMTX checksum..."
    local actual_checksum
    actual_checksum="$(shasum -a 256 "${archive}" | cut -d' ' -f1)"
    if [ "${actual_checksum}" != "${MEDIAMTX_SHA256}" ]; then
        echo "ERROR: MediaMTX checksum mismatch."
        echo "  Expected: ${MEDIAMTX_SHA256}"
        echo "  Actual:   ${actual_checksum}"
        exit 1
    fi

    tar -xzf "${archive}" -C "${MEDIAMTX_DOWNLOAD_DIR}"
    chmod +x "${binary}"
    MEDIAMTX_BIN="${binary}"
}

start_container() {
    # Remove any existing container
    ${CONTAINER_CMD} rm -f "${CONTAINER_NAME}" 2>/dev/null || true

    echo "Starting MediaMTX container..."
    ${CONTAINER_CMD} run -d \
        --name "${CONTAINER_NAME}" \
        -p 8889:8889 \
        -p 9997:9997 \
        -v "${CONFIG_FILE}:/mediamtx.yml:ro" \
        "${IMAGE}"
}

start_binary() {
    ensure_mediamtx_binary
    echo "Starting MediaMTX binary..."
    : > "${MEDIAMTX_LOG}"
    "${MEDIAMTX_BIN}" "${CONFIG_FILE}" > "${MEDIAMTX_LOG}" 2>&1 &
    MEDIAMTX_PID="$!"
}

show_mediamtx_logs() {
    if [ -n "${CONTAINER_CMD}" ]; then
        ${CONTAINER_CMD} logs "${CONTAINER_NAME}" 2>&1 | tail -20
    elif [ -f "${MEDIAMTX_LOG}" ]; then
        tail -20 "${MEDIAMTX_LOG}"
    fi
}

cleanup() {
    if [ -n "${CONTAINER_CMD}" ]; then
        echo "Stopping MediaMTX container..."
        ${CONTAINER_CMD} rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    elif [ -n "${MEDIAMTX_PID}" ]; then
        echo "Stopping MediaMTX process..."
        kill "${MEDIAMTX_PID}" 2>/dev/null || true
        wait "${MEDIAMTX_PID}" 2>/dev/null || true
    fi
    MEDIAMTX_PID=""
}
trap cleanup EXIT

start_mediamtx() {
    CONTAINER_CMD=""
    if command -v docker &>/dev/null; then
        CONTAINER_CMD="docker"
        start_container
    elif command -v podman &>/dev/null; then
        CONTAINER_CMD="podman"
        start_container
    elif integration_required; then
        echo "No container runtime found; using direct MediaMTX binary fallback."
        start_binary
    else
        echo "SKIP: No container runtime (docker/podman) found."
        exit 0
    fi
}

wait_for_mediamtx() {
    echo "Waiting for MediaMTX to start..."
    for i in $(seq 1 "${MEDIAMTX_READY_TIMEOUT_SECONDS}"); do
        if curl -s http://localhost:9997/v3/config/get >/dev/null 2>&1; then
            echo "MediaMTX is ready."
            return 0
        fi
        if [ "$i" -eq "${MEDIAMTX_READY_TIMEOUT_SECONDS}" ]; then
            echo "ERROR: MediaMTX did not start within ${MEDIAMTX_READY_TIMEOUT_SECONDS} seconds."
            show_mediamtx_logs
            return 1
        fi
        sleep 1
    done
}

MEDIAMTX_STARTED=false
for attempt in $(seq 1 "${MEDIAMTX_STARTUP_ATTEMPTS}"); do
    echo "--- MediaMTX startup attempt ${attempt} of ${MEDIAMTX_STARTUP_ATTEMPTS} ---"

    if start_mediamtx && wait_for_mediamtx; then
        MEDIAMTX_STARTED=true
        break
    fi

    echo "MediaMTX startup attempt ${attempt} failed."
    cleanup

    if [ "$attempt" -lt "${MEDIAMTX_STARTUP_ATTEMPTS}" ]; then
        echo "Retrying MediaMTX startup in ${MEDIAMTX_RETRY_DELAY_SECONDS} second(s)..."
        sleep "${MEDIAMTX_RETRY_DELAY_SECONDS}"
    fi
done

if [ "${MEDIAMTX_STARTED}" != true ]; then
    echo "ERROR: MediaMTX failed to start after ${MEDIAMTX_STARTUP_ATTEMPTS} attempt(s)."
    exit 1
fi

# Run the integration test via xcodebuild
echo "Running integration test..."
cd "${PROJECT_DIR}"
LOCALCUT_RUN_MEDIAMTX_INTEGRATION=1 "${XCODEBUILD_BIN}" test \
    -project "LocalCut Studio.xcodeproj" \
    -scheme "LocalCut Studio" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -only-testing:"LocalCut StudioTests/WhipMediaMTXIntegrationTests" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 300 \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -30

echo "=== Done ==="
