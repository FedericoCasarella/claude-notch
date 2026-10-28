// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            path: "Sources/ClaudeNotch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
