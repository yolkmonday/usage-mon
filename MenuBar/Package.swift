// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "UsageMenuBar",
            path: "Sources/UsageMenuBar",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
