// swift-tools-version: 6.2
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "CalShareCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CalShareCore", targets: ["CalShareCore"]),
    ],
    targets: [
        .target(
            name: "CalShareCore",
            // The app target's SWIFT_STRICT_MEMORY_SAFETY doesn't reach a package; this does.
            swiftSettings: [.strictMemorySafety()],
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(
            name: "CalShareCoreTests",
            dependencies: ["CalShareCore"]),
    ]
)
