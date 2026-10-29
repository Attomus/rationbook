// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "Rationbook",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RationbookCore", targets: ["RationbookCore"]),
        .library(name: "RationbookUI", targets: ["RationbookUI"]),
        .executable(name: "rationbook", targets: ["RationbookCLI"]),
        .executable(name: "RationbookMenu", targets: ["RationbookApp"]),
        .executable(name: "rationbook-claude-helper", targets: ["ClaudeStatusLineHelper"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(
            name: "RationbookCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(name: "RationbookCLI", dependencies: ["RationbookCore"]),
        .target(
            name: "RationbookUI",
            dependencies: ["RationbookCore"],
            path: "Sources/RationbookApp",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "RationbookApp",
            dependencies: ["RationbookUI"],
            path: "Sources/RationbookPublicApp"
        ),
        .executableTarget(name: "ClaudeStatusLineHelper", dependencies: ["RationbookCore"]),
        .testTarget(
            name: "RationbookCoreTests",
            dependencies: ["RationbookCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
