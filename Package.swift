// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "Pulse",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources")],
            // Sparkle.framework: in Contents/Frameworks of the app (package.sh), beside build.sh's bare executable
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@loader_path"])]
        )
    ]
)
