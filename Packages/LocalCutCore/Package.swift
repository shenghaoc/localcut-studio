// swift-tools-version: 6.0
import PackageDescription

// LocalCutCore — the pure, platform-light engine logic behind LocalCut Studio.
//
// Everything here must build and test *without* SwiftUI/AppKit and without the
// app's `@Observable` orchestration, so the fast loop is:
//
//     swift test --package-path Packages/LocalCutCore
//
// App-facing AVFoundation/SwiftUI glue stays in the Xcode target; only testable
// pure logic (time math, transition layout, render planning, keyframes,
// capability-tier decisions, serialization helpers) migrates here. See
// README.md for the migration plan.
let package = Package(
    name: "LocalCutCore",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "LocalCutCore", targets: ["LocalCutCore"]),
    ],
    targets: [
        // swift-tools-version 6.0 already defaults to the Swift 6 language mode,
        // matching the app target's SWIFT_VERSION = 6.0.
        .target(name: "LocalCutCore"),
        .testTarget(
            name: "LocalCutCoreTests",
            dependencies: ["LocalCutCore"]),
    ])
