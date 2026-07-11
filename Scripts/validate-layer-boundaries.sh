#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN_SOURCES="${ROOT_DIR}/Packages/LocalCutCore/Sources/LocalCutDomain"
APPLE_CORE_SOURCES="${ROOT_DIR}/Packages/LocalCutCore/Sources/LocalCutCore"
PLATFORM_SOURCES="${ROOT_DIR}/Packages/LocalCutCore/Sources/LocalCutPlatform"
APP_SOURCES="${ROOT_DIR}/LocalCut Studio"

domain_forbidden_imports='^import (SwiftUI|AppKit|AVKit|AVFoundation|CoreMedia|CoreGraphics|CoreVideo|VideoToolbox|Accelerate|Metal|MetalKit|ScreenCaptureKit|Observation|WebRTC|Lottie|os)$'
if rg -n "${domain_forbidden_imports}" "${DOMAIN_SOURCES}"; then
    echo "ERROR: LocalCutDomain must remain Foundation-only and cross-platform."
    exit 1
fi

if rg -n '^import LocalCutCore$' "${DOMAIN_SOURCES}"; then
    echo "ERROR: LocalCutDomain must not depend on the Apple media core."
    exit 1
fi

if rg -n '^import LocalCutPlatform$' "${DOMAIN_SOURCES}" "${APPLE_CORE_SOURCES}"; then
    echo "ERROR: lower layers must not depend on the macOS platform layer."
    exit 1
fi

apple_core_forbidden_imports='^import (SwiftUI|AppKit|AVKit|AVFoundation|WebRTC|Lottie)$'
if rg -n "${apple_core_forbidden_imports}" "${APPLE_CORE_SOURCES}"; then
    echo "ERROR: LocalCutCore must not import UI, AVFoundation, or app-layer dependencies."
    exit 1
fi

platform_forbidden_imports='^import (SwiftUI|Charts|AppIntents)$'
if rg -n "${platform_forbidden_imports}" "${PLATFORM_SOURCES}"; then
    echo "ERROR: LocalCutPlatform must remain presentation-independent."
    exit 1
fi

if rg -n '(^|[^A-Za-z0-9_])LocalCut_Studio([^A-Za-z0-9_]|$)' \
    "${DOMAIN_SOURCES}" "${APPLE_CORE_SOURCES}" "${PLATFORM_SOURCES}"; then
    echo "ERROR: package targets must not depend on the macOS app module."
    exit 1
fi

if rg -n '^import (WebRTC|ScreenCaptureKit|Lottie)$|^@preconcurrency import (WebRTC|ScreenCaptureKit)$' "${APP_SOURCES}"; then
    echo "ERROR: reusable WebRTC, ScreenCaptureKit, and Lottie integration belongs in LocalCutPlatform."
    exit 1
fi

echo "LocalCutDomain, LocalCutCore, and LocalCutPlatform layer boundaries validated."
