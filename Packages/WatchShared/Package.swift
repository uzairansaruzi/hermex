// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "WatchShared", targets: ["WatchShared"]),
    ],
    targets: [
        .target(
            name: "WatchShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WatchSharedTests",
            dependencies: ["WatchShared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
