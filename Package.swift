// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MacEntire",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MacEntireCore",
            targets: ["MacEntireCore"]
        ),
        .executable(
            name: "MacEntireApp",
            targets: ["MacEntireApp"]
        )
    ],
    targets: [
        .target(
            name: "MacEntireCore"
        ),
        .executableTarget(
            name: "MacEntireApp",
            dependencies: ["MacEntireCore"]
        ),
        .testTarget(
            name: "MacEntireCoreTests",
            dependencies: ["MacEntireCore"]
        ),
        .testTarget(
            name: "MacEntireAppTests",
            dependencies: ["MacEntireApp"]
        )
    ]
)
