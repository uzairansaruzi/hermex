// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermexWatchRoot",
    platforms: [
        .macOS(.v14),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "HermexWatchRoot", targets: ["HermexWatchRoot"]),
    ],
    dependencies: [
        .package(path: "../WatchShared"),
    ],
    targets: [
        .target(
            name: "HermexWatchRoot",
            dependencies: ["WatchShared"]
        ),
        .testTarget(name: "HermexWatchRootTests", dependencies: ["HermexWatchRoot"]),
    ],
    swiftLanguageModes: [.v5]
)
