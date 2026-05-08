// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotionCodexBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NotionCodexBridge", targets: ["NotionCodexBridge"]),
        .library(name: "NotionCodexBridgeCore", targets: ["NotionCodexBridgeCore"])
    ],
    targets: [
        .target(
            name: "NotionCodexBridgeCore",
            linkerSettings: [
                .linkedFramework("CryptoKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "NotionCodexBridge",
            dependencies: ["NotionCodexBridgeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "NotionCodexBridgeCoreTests",
            dependencies: ["NotionCodexBridgeCore"]
        )
    ]
)
