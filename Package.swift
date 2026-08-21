// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Killdeer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KilldeerCore", targets: ["KilldeerCore"]),
        .executable(name: "killdeer", targets: ["KilldeerCLI"]),
        .executable(name: "killdeer-app", targets: ["KilldeerApp"])
    ],
    targets: [
        .target(name: "KilldeerCore"),
        .executableTarget(
            name: "KilldeerCLI",
            dependencies: ["KilldeerCore"]
        ),
        .executableTarget(
            name: "KilldeerApp",
            dependencies: ["KilldeerCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/KilldeerApp/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "KilldeerCoreTests",
            dependencies: ["KilldeerCore"]
        )
    ]
)
