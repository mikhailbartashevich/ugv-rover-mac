// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "UGVControl",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "UGVControl", path: "Sources/UGVControl")
    ],
    swiftLanguageModes: [.v5]
)
