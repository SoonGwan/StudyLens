// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "StudyLens",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StudyLens", targets: ["StudyLens"])
    ],
    targets: [
        .executableTarget(
            name: "StudyLens",
            path: "Sources/StudyLens"
        ),
        .testTarget(
            name: "StudyLensTests",
            dependencies: ["StudyLens"],
            path: "Tests/StudyLensTests"
        )
    ]
)
