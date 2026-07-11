// swift-tools-version: 6.0
import PackageDescription

// LocalCutDomain is the Foundation-only cross-platform domain layer.
// LocalCutCore is the Apple media layer built only on macOS.
// Both stay independent of SwiftUI/AppKit and the app's orchestration.
// The fast macOS loop is:
//
//     swift test --package-path Packages/LocalCutCore
//
// App-facing AVFoundation/SwiftUI glue stays in the Xcode target; only testable
// pure logic (time math, transition layout, render planning, keyframes,
// capability-tier decisions, serialization helpers) migrates here. See
// README.md for the migration plan.
var products: [Product] = [
    .library(name: "LocalCutDomain", targets: ["LocalCutDomain"]),
]

var targets: [Target] = [
    .target(name: "LocalCutDomain"),
    .testTarget(
        name: "LocalCutDomainTests",
        dependencies: ["LocalCutDomain"]),
]

#if os(macOS)
products.append(
    .library(name: "LocalCutCore", targets: ["LocalCutDomain", "LocalCutCore"])
)
targets.append(
    .target(
        name: "LocalCutCore",
        dependencies: ["LocalCutDomain"])
)
targets.append(
    .testTarget(
        name: "LocalCutCoreTests",
        dependencies: ["LocalCutDomain", "LocalCutCore"])
)
#endif

let package = Package(
    name: "LocalCutCore",
    platforms: [
        .macOS("26.0"),
    ],
    products: products,
    targets: targets)
