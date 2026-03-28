// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeTracker",
            path: "Sources/ClaudeTracker"
        )
    ]
)
