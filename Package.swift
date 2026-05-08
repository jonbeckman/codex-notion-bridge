// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexNotionBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexNotionBridge", targets: ["CodexNotionBridge"]),
        .library(name: "CodexNotionBridgeCore", targets: ["CodexNotionBridgeCore"])
    ],
    targets: [
        .target(
            name: "CodexNotionBridgeCore",
            linkerSettings: [
                .linkedFramework("CryptoKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "CodexNotionBridge",
            dependencies: ["CodexNotionBridgeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "CodexNotionBridgeCoreTests",
            dependencies: ["CodexNotionBridgeCore"]
        )
    ]
)
