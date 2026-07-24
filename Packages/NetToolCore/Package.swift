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
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-certificates.git",
            exact: "1.19.3"
        )
    ],
    targets: [
        .target(
            name: "NetToolCore",
            dependencies: [
                .product(
                    name: "X509",
                    package: "swift-certificates"
                )
            ]
        ),
        .testTarget(
            name: "NetToolCoreTests",
            dependencies: ["NetToolCore"]
        )
    ]
)
