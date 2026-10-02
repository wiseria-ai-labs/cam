// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeAccountManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeAccountManager"),
        .testTarget(name: "ClaudeAccountManagerTests", dependencies: ["ClaudeAccountManager"]),
    ]
)
