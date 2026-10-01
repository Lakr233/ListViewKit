// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ListViewKit",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "ListViewKit", targets: ["ListViewKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/DisplayLink.git", from: "3.0.1"),
    ],
    targets: [
        .target(
            name: "ListViewKit",
            dependencies: [
                "DisplayLink",
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "ListViewKitTests",
            dependencies: ["ListViewKit"]
        ),
        .executableTarget(
            name: "ListViewKitBenchmarks",
            dependencies: ["ListViewKit"],
            path: "Benchmarks",
            exclude: ["README.md"]
        ),
    ]
)
