// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "gpu-fan",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FanCore"),
        .executableTarget(
            name: "fancurvectl",
            dependencies: ["FanCore"]
        ),
        .executableTarget(
            name: "fancurved",
            dependencies: ["FanCore"]
        ),
        .executableTarget(
            name: "GpuFanApp",
            dependencies: ["FanCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
