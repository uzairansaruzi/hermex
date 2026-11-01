// swift-tools-version:5.9
// Renders the catalog's authoritative SF Symbol names through the real iOS UIKit runtime on a
// Simulator (never AppKit/NSImage, never a substitute icon library) — see
// scripts/generate-icon-previews.mjs, the only intended entry point for this package.
import PackageDescription

let package = Package(
    name: "HermexIconRenderer",
    platforms: [.iOS(.v17)],
    targets: [
        .testTarget(name: "IconRenderTests")
    ]
)
