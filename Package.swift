// swift-tools-version: 5.9
// Test-only package: builds the Foundation-only logic in `KittenTTS2App/KittenTTS2App/Core`
// so it can be unit tested with `swift test` (no Xcode project, simulator or model assets required).
// The iOS app compiles the same files directly through KittenTTS2App.xcodeproj.
import PackageDescription

let package = Package(
    name: "KittenTTS2Core",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "KittenCore", targets: ["KittenCore"]),
    ],
    targets: [
        .target(name: "KittenCore", path: "KittenTTS2App/KittenTTS2App/Core"),
        .testTarget(name: "KittenCoreTests", dependencies: ["KittenCore"], path: "KittenTTS2App/KittenTTS2AppTests"),
    ]
)
