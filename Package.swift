// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PrepareDisk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PrepareDisk", path: "Sources")
    ]
)
