// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "herdr-term",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "HerdrTerm", targets: ["HerdrTerm"]),
        .library(name: "HerdrClient", targets: ["HerdrClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/briannadoubt/GhosttyKit.git", exact: "0.8.0"),
    ],
    targets: [
        .target(
            name: "HerdrClient",
            path: "Sources/HerdrClient"
        ),
        .executableTarget(
            name: "HerdrTerm",
            dependencies: [
                "HerdrClient",
                .product(name: "GhosttyKit", package: "GhosttyKit"),
            ],
            path: "Sources/HerdrTerm",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
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
