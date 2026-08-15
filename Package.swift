// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentAwakeHelper", targets: ["AgentAwakeHelper"]),
    ],
    targets: [
        .executableTarget(name: "AgentAwakeHelper"),
    ]
)
