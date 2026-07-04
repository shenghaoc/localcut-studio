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

patch_macos_headers() {
    local macos_headers="$1"

    # stasel's M140 macOS slice is the newest usable binary, but its Obj-C
    # umbrella/header set still carries a few iOS-only public headers when we
    # fill missing imports from the iOS slice. Those headers pull UIKit or
    # AVAudioSession into the macOS module and break `import WebRTC`.
    local excluded_headers=(
        "RTCAudioSession.h"
        "RTCAudioSessionConfiguration.h"
        "RTCCameraPreviewView.h"
        "RTCEAGLVideoView.h"
        "RTCMTLVideoView.h"
        "UIDevice+RTCDevice.h"
    )

    local umbrella="${macos_headers}/WebRTC.h"
    for header in "${excluded_headers[@]}"; do
        local tmp="${umbrella}.tmp"
        grep -vF "#import <WebRTC/${header}>" "${umbrella}" > "${tmp}"
        mv "${tmp}" "${umbrella}"
        rm -f "${macos_headers}/${header}"
    done

    if [ -f "${macos_headers}/RTCMTLNSVideoView.h" ] &&
       ! grep -qF "#import <WebRTC/RTCMTLNSVideoView.h>" "${umbrella}"; then
        local tmp="${umbrella}.tmp"
        awk '
            $0 == "#import <WebRTC/RTCNetworkMonitor.h>" {
                print
                print "#import <WebRTC/RTCMTLNSVideoView.h>"
                next
            }
            { print }
        ' "${umbrella}" > "${tmp}"
        mv "${tmp}" "${umbrella}"
    fi

    local renderer="${macos_headers}/RTCVideoRenderer.h"
    if [ -f "${renderer}" ] &&
       grep -qF "#import <UIKit/UIKit.h>" "${renderer}" &&
       ! grep -qF "#import <CoreGraphics/CoreGraphics.h>" "${renderer}"; then
        local tmp="${renderer}.tmp"
        awk '
            $0 == "#import <UIKit/UIKit.h>" {
                print "#if TARGET_OS_IPHONE"
                print "#import <UIKit/UIKit.h>"
                print "#else"
                print "#import <CoreGraphics/CoreGraphics.h>"
                print "#endif"
                next
            }
            { print }
        ' "${renderer}" > "${tmp}"
        mv "${tmp}" "${renderer}"
    fi
}

echo "=== LocalCutWebRTC: Downloading WebRTC ${VERSION} ==="

# Skip if XCFramework already exists
if [ -d "${XCFRAMEWORK}" ]; then
    echo "XCFramework already exists at ${XCFRAMEWORK}"
    echo "Validating existing macOS headers."
    patch_macos_headers "${XCFRAMEWORK}/macos-x86_64_arm64/WebRTC.framework/Headers"
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
    echo "  Headers after fix: $(ls "${MACOS_HEADERS}" | wc -l | tr -d ' ')"
fi

patch_macos_headers "${MACOS_HEADERS}"

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
