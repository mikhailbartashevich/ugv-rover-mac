// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "UGVControl",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "UGVControl", targets: ["UGVControl"]),
        .library(name: "RoverKit", targets: ["RoverKit"]),
    ],
    targets: [
        // Rover protocol, connection, video, Mac networking and Wi‑Fi provisioning. No UI.
        .target(name: "RoverKit"),
        // The SwiftUI app.
        .executableTarget(name: "UGVControl", dependencies: ["RoverKit"]),
        .testTarget(name: "RoverKitTests", dependencies: ["RoverKit"]),
    ],
    swiftLanguageModes: [.v5]
)
