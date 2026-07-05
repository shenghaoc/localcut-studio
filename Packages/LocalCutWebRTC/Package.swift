// swift-tools-version: 6.0
import PackageDescription

// LocalCutWebRTC — macOS WebRTC wrapper package.
//
// Wraps the stasel/WebRTC XCFramework.
// M140 is the newest verified stasel release before the macOS public-header
// packaging regression introduced in later release artifacts.
//
// Source: https://github.com/stasel/WebRTC
// Version: 140.0.0 (M140)
// License: BSD-3-Clause
// Size: ~40 MB (XCFramework zip), ~87 MB extracted
//
// To download and validate the XCFramework:
//   ./Packages/LocalCutWebRTC/Scripts/download-webrtc.sh
//
// The XCFramework is gitignored and must be downloaded before building.
let package = Package(
    name: "LocalCutWebRTC",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(
            name: "WebRTC",
            targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            path: "WebRTC.xcframework"
        ),
    ]
)
