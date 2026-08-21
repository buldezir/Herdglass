// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Herdglass",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Herdglass", targets: ["Herdglass"]),
        .library(name: "HerdrClient", targets: ["HerdrClient"]),
    ],
    targets: [
        // libghostty, built from the pinned ghostty checkout in Vendor/ghostty
        // by Scripts/libghostty.sh. Its module map names the module GhosttyKit,
        // which is what `import GhosttyKit` resolves to.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .target(
            name: "HerdrClient",
            path: "Sources/HerdrClient"
        ),
        .executableTarget(
            name: "Herdglass",
            dependencies: [
                "HerdrClient",
                "GhosttyKit",
            ],
            path: "Sources/Herdglass",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "HerdrClientTests",
            dependencies: ["HerdrClient"],
            path: "Tests/HerdrClientTests"
        ),
    ]
)
