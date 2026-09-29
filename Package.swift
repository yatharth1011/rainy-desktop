// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RainyDesktop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RainyDesktop",
            path: "Sources/RainyDesktop",
            exclude: ["Rendering/Shaders"]
        )
    ]
)
