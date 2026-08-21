// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Killdeer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KilldeerCore", targets: ["KilldeerCore"]),
        .executable(name: "killdeer", targets: ["KilldeerCLI"])
    ],
    targets: [
        .target(name: "KilldeerCore"),
        .executableTarget(
            name: "KilldeerCLI",
            dependencies: ["KilldeerCore"]
        ),
        .testTarget(
            name: "KilldeerCoreTests",
            dependencies: ["KilldeerCore"]
        )
    ]
)
