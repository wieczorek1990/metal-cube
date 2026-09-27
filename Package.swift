// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "metal-cube",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "metal-cube",
            path: "Sources"
        )
    ]
)
