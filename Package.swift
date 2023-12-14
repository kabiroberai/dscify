// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "dscify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "dscify",
            targets: ["dscify"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "dscify",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]
        ),
        .testTarget(
            name: "dscifyTests",
            dependencies: ["dscify"]
        ),
    ]
)
