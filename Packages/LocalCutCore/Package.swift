// swift-tools-version: 6.0
import PackageDescription

// LocalCutDomain is the Foundation-only cross-platform domain layer.
// LocalCutCore is the Apple media layer built only on macOS.
// LocalCutPlatform owns reusable macOS integrations such as capture, overlays,
// and WebRTC publishing. All three stay independent of SwiftUI/AppKit and the
// app's orchestration.
// The fast macOS loop is:
//
//     swift test --package-path Packages/LocalCutCore
//
// Each library product names only its own root target. SwiftPM links target
// dependencies transitively; including LocalCutDomain in the LocalCutCore
// product as well would expose the same domain module through two products when
// an app links LocalCutDomain and LocalCutCore together.
var products: [Product] = [
    .library(name: "LocalCutDomain", targets: ["LocalCutDomain"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "LocalCutDomain"),
    .testTarget(
        name: "LocalCutDomainTests",
        dependencies: ["LocalCutDomain"]),
]

#if os(macOS)
dependencies.append(
    .package(url: "https://github.com/webrtc-sdk/Specs.git", exact: "125.6422.09")
)
dependencies.append(
    .package(url: "https://github.com/airbnb/lottie-ios.git", exact: "4.6.1")
)
products.append(
    .library(name: "LocalCutCore", targets: ["LocalCutCore"])
)
products.append(
    .library(name: "LocalCutPlatform", targets: ["LocalCutPlatform"])
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
targets.append(
    .target(
        name: "LocalCutPlatform",
        dependencies: [
            "LocalCutDomain",
            "LocalCutCore",
            .product(name: "Lottie", package: "lottie-ios"),
            .product(name: "WebRTC", package: "Specs"),
        ],
        swiftSettings: [
            .define("LOCALCUT_ENABLE_WEBRTC"),
        ])
)
#endif

let package = Package(
    name: "LocalCutCore",
    platforms: [
        .macOS("26.0"),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets)
