// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pulse", resources: [.copy("Resources")])
    ]
)
