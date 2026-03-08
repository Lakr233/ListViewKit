// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ListExampleMac",
    platforms: [
        .macOS(.v11),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ListExampleMac",
            dependencies: [
                .product(name: "ListViewKit", package: "ListViewKit"),
            ],
            path: "Sources",
            exclude: ["Info.plist"]
        ),
    ]
)
