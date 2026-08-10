// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ListViewKit",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ListViewKit", targets: ["ListViewKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink", from: "2.0.8"),
    ],
    targets: [
        .target(
            name: "ListViewKit",
            dependencies: [
                "MSDisplayLink",
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
