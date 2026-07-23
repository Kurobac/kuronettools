// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NetToolCore",
    products: [
        .library(
            name: "NetToolCore",
            targets: ["NetToolCore"]
        )
    ],
    targets: [
        .target(name: "NetToolCore"),
        .testTarget(
            name: "NetToolCoreTests",
            dependencies: ["NetToolCore"]
        )
    ]
)
