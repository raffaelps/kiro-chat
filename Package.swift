// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "KiroChat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KiroChat", targets: ["KiroChatApp"]),
        .executable(name: "kiro-chat-mcp", targets: ["KiroChatMCP"]),
        .library(name: "KiroChatCore", targets: ["KiroChatCore"]),
    ],
    targets: [
        .target(
            name: "KiroChatCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "KiroChatMCP",
            dependencies: ["KiroChatCore"]
        ),
        .executableTarget(
            name: "KiroChatApp",
            dependencies: ["KiroChatCore"]
        ),
        .testTarget(
            name: "KiroChatCoreTests",
            dependencies: ["KiroChatCore"]
        ),
    ]
)
