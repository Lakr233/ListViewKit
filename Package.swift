// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ListViewKit",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v13),
    ],
    products: [
        .library(name: "ListViewKit", targets: ["ListViewKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/Lakr233/SpringInterpolation", from: "1.3.1"),
    ],
    targets: [
        .target(
            name: "ListViewKit",
            dependencies: [
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                "SpringInterpolation",
            ]
        ),
    ]
)
