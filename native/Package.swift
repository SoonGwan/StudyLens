// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "StudyLensHelper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "studylens-helper", targets: ["studylens-helper"])
    ],
    targets: [
        .target(
            name: "SelectionCore",
            path: "Sources/SelectionCore"
        ),
        .executableTarget(
            name: "studylens-helper",
            dependencies: ["SelectionCore"],
            path: "Sources/studylens-helper"
        ),
        .testTarget(
            name: "SelectionCoreTests",
            dependencies: ["SelectionCore"],
            path: "Tests/SelectionCoreTests"
        )
    ]
)
