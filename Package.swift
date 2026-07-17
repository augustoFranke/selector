// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Selector",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Selector",
            path: "Sources/Selector"
        ),
        .testTarget(
            name: "SelectorTests",
            dependencies: ["Selector"],
            path: "Tests/SelectorTests"
        )
    ]
)
