// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KittenCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "KittenCore", targets: ["KittenCore"]),
    ],
    targets: [
        .target(name: "KittenCore", path: "Sources/KittenCore"),
        .testTarget(
            name: "KittenCoreTests",
            dependencies: ["KittenCore"],
            path: "Tests/KittenCoreTests"
        ),
    ]
)
