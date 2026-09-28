import XCTest
@testable import HermesMobile

/// Icon precedence for filenames: exact name, then `tsconfig.*.json`, then the longest
/// extension chain, then the default document glyph.
final class FileIconTests: XCTestCase {
    func testExactNameBeatsExtension() {
        XCTAssertEqual(FileIcon.resolve("package.json"), .package)
        XCTAssertEqual(FileIcon.resolve("settings.json"), .json)
        XCTAssertEqual(FileIcon.resolve("README.md"), .readme)
        XCTAssertEqual(FileIcon.resolve("notes.md"), .markdown)
        XCTAssertEqual(FileIcon.resolve("Dockerfile"), .docker)
        XCTAssertEqual(FileIcon.resolve("CLAUDE.md"), .claude)
    }

    func testTsconfigVariantsShareOneIcon() {
        XCTAssertEqual(FileIcon.resolve("tsconfig.json"), .tsconfig)
        XCTAssertEqual(FileIcon.resolve("tsconfig.build.json"), .tsconfig)
        XCTAssertEqual(FileIcon.resolve("vite.config.ts"), .vite)
    }

    func testLongestExtensionChainWins() {
        XCTAssertEqual(FileIcon.resolve(".env.local"), .text)
        XCTAssertEqual(FileIcon.resolve("archive.tar.gz"), .zip)
        XCTAssertEqual(FileIcon.resolve("Post.mdx.tsx"), .markdown)
    }

    func testResolvesFromPathsAndIgnoresPositionSuffixAndCase() {
        XCTAssertEqual(FileIcon.resolve("Sources/App/ChatView.swift"), .swift)
        XCTAssertEqual(FileIcon.resolve("Sources/App/ChatView.swift:12:3"), .swift)
        XCTAssertEqual(FileIcon.resolve("Photo.PNG"), .image)
    }

    func testUnknownFilesGetTheDefaultGlyph() {
        XCTAssertEqual(FileIcon.resolve("Makefile"), .default)
        XCTAssertEqual(FileIcon.resolve("data.unknownext"), .default)
        XCTAssertEqual(FileIcon.resolve(""), .default)
    }

    func testEveryIconHasAnAsset() {
        for icon in FileIcon.allCases {
            XCTAssertNotNil(icon.uiImage, "\(icon.assetName) is missing from the asset catalog")
        }
    }
}
