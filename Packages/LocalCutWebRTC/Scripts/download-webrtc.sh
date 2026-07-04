#!/bin/bash
# Downloads the stasel/WebRTC XCFramework and validates the macOS slice.
#
# Usage: ./Packages/LocalCutWebRTC/Scripts/download-webrtc.sh
#
# stasel/WebRTC releases after M140 currently have incomplete macOS public
# headers. M140 is the newest verified upstream release with RTCAudioSource.h
# and the other public imports present in the macOS framework slice.
#
# Source: https://github.com/stasel/WebRTC
# Version: 140.0.0 (M140)
# License: BSD-3-Clause

set -euo pipefail

VERSION="140.0.0"
MILESTONE="140"
URL="https://github.com/stasel/WebRTC/releases/download/${VERSION}/WebRTC-M${MILESTONE}.xcframework.zip"
CHECKSUM="0d61faf67dd145545bf8a0017bdcdbe7a9a1f3a96cce0d501e526655711d98d2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"
DOWNLOAD_DIR="${PACKAGE_DIR}/.build/webrtc-download"
XCFRAMEWORK="${PACKAGE_DIR}/WebRTC.xcframework"

echo "=== LocalCutWebRTC: Downloading WebRTC ${VERSION} ==="

# Skip if XCFramework already exists
if [ -d "${XCFRAMEWORK}" ]; then
    echo "XCFramework already exists at ${XCFRAMEWORK}"
    echo "Delete it to re-download."
    exit 0
fi

# Download
mkdir -p "${DOWNLOAD_DIR}"
ZIP_FILE="${DOWNLOAD_DIR}/WebRTC-M${MILESTONE}.xcframework.zip"

if [ ! -f "${ZIP_FILE}" ]; then
    echo "Downloading ${URL}..."
    curl -L -o "${ZIP_FILE}" "${URL}"
    
    # Verify checksum
    echo "Verifying checksum..."
    ACTUAL_CHECKSUM=$(shasum -a 256 "${ZIP_FILE}" | cut -d' ' -f1)
    if [ "${ACTUAL_CHECKSUM}" != "${CHECKSUM}" ]; then
        echo "ERROR: Checksum mismatch!"
        echo "  Expected: ${CHECKSUM}"
        echo "  Actual:   ${ACTUAL_CHECKSUM}"
        rm -f "${ZIP_FILE}"
        exit 1
    fi
    echo "Checksum verified."
else
    echo "Using cached download: ${ZIP_FILE}"
fi

# Extract
echo "Extracting..."
rm -rf "${DOWNLOAD_DIR}/extracted"
mkdir -p "${DOWNLOAD_DIR}/extracted"
unzip -q "${ZIP_FILE}" -d "${DOWNLOAD_DIR}/extracted"

# Validate macOS slice headers.
echo "Validating macOS slice headers..."
IOS_HEADERS="${DOWNLOAD_DIR}/extracted/WebRTC.xcframework/ios-arm64/WebRTC.framework/Headers"
MACOS_HEADERS="${DOWNLOAD_DIR}/extracted/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework/Headers"

if [ ! -d "${IOS_HEADERS}" ]; then
    echo "ERROR: iOS headers not found at ${IOS_HEADERS}"
    exit 1
fi

if [ ! -d "${MACOS_HEADERS}" ]; then
    echo "ERROR: macOS headers not found at ${MACOS_HEADERS}"
    exit 1
fi

IOS_COUNT=$(ls "${IOS_HEADERS}" | wc -l | tr -d ' ')
MACOS_COUNT=$(ls "${MACOS_HEADERS}" | wc -l | tr -d ' ')
echo "  iOS headers:   ${IOS_COUNT}"
echo "  macOS headers: ${MACOS_COUNT}"

if [ ! -f "${MACOS_HEADERS}/RTCAudioSource.h" ]; then
    echo "ERROR: macOS slice is missing RTCAudioSource.h"
    echo "This is the known stasel/WebRTC macOS header packaging regression."
    exit 1
fi

MISSING=0
MISSING_HEADERS=()
while IFS= read -r header; do
    if [ ! -f "${MACOS_HEADERS}/${header}" ]; then
        MISSING_HEADERS+=("$header")
        MISSING=1
    fi
done < <(grep -o '<WebRTC/[^>]*>' "${MACOS_HEADERS}/WebRTC.h" | sed 's#<WebRTC/##; s#>##')

if [ "${MISSING}" -ne 0 ]; then
    echo "  Copying ${#MISSING_HEADERS[@]} missing headers from iOS slice..."
    for header in "${MISSING_HEADERS[@]}"; do
        if [ -f "${IOS_HEADERS}/${header}" ]; then
            cp "${IOS_HEADERS}/${header}" "${MACOS_HEADERS}/${header}"
            echo "    Copied: ${header}"
        else
            echo "    WARNING: ${header} not found in iOS slice either"
        fi
    done
    # Also copy the complete umbrella header from iOS
    cp "${IOS_HEADERS}/WebRTC.h" "${MACOS_HEADERS}/WebRTC.h"
    echo "  Headers after fix: $(ls "${MACOS_HEADERS}" | wc -l | tr -d ' ')"
fi

# Move to final location
echo "Installing XCFramework..."
mv "${DOWNLOAD_DIR}/extracted/WebRTC.xcframework" "${XCFRAMEWORK}"

# Copy LICENSE
cp "${XCFRAMEWORK}/LICENSE" "${PACKAGE_DIR}/LICENSE.WebRTC" 2>/dev/null || true

# Cleanup
rm -rf "${DOWNLOAD_DIR}"

echo "=== Done ==="
echo "XCFramework: ${XCFRAMEWORK}"
echo "Size: $(du -sh "${XCFRAMEWORK}" | cut -f1)"
