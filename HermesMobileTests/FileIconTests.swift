import XCTest
@testable import HermesMobile

final class FileIconTests: XCTestCase {
    func testLongestExtensionChainWins() {
        XCTAssertEqual(FileIcon.resolve(".env.local"), .text)
        XCTAssertEqual(FileIcon.resolve("archive.tar.gz"), .zip)
        XCTAssertEqual(FileIcon.resolve("Post.mdx.tsx"), .markdown)
    }

    func testEveryIconHasAnAsset() {
        for icon in FileIcon.allCases {
            XCTAssertNotNil(icon.uiImage, "\(icon.assetName) is missing from the asset catalog")
        }
    }
}
