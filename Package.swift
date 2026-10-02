// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "cam",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "cam"),
        .testTarget(name: "camTests", dependencies: ["cam"]),
    ]
)
