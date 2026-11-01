import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `HermexAvatar` (`HermexAvatar.swift`): a system-image identity badge sized to the
/// shared `HermesAvatarSize` diameters, each carrying the accepted `HermesIconSize.Avatar` icon at
/// the approved pairing (32→20, 40→24, 48→32). A SwiftUI view tree isn't inspectable at runtime
/// without a rendering harness, so the size pairing is a pure contract and adoption elsewhere is a
/// source contract.
final class HermexAvatarTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    // MARK: - Pure contracts: the accepted 32/40/48 <-> 20/24/32 pairing

    func testEveryAvatarSizeCarriesTheAcceptedIconSize() {
        XCTAssertEqual(HermexAvatar.iconSize(for: .small), HermesIconSize.Avatar.small)
        XCTAssertEqual(HermexAvatar.iconSize(for: .small), 20)
        XCTAssertEqual(HermexAvatar.iconSize(for: .medium), HermesIconSize.Avatar.medium)
        XCTAssertEqual(HermexAvatar.iconSize(for: .medium), 24)
        XCTAssertEqual(HermexAvatar.iconSize(for: .large), HermesIconSize.Avatar.large)
        XCTAssertEqual(HermexAvatar.iconSize(for: .large), 32)
    }

    func testAvatarDiametersMatchTheSharedHermesAvatarSizeScale() {
        XCTAssertEqual(HermesAvatarSize.small.rawValue, 32)
        XCTAssertEqual(HermesAvatarSize.medium.rawValue, 40)
        XCTAssertEqual(HermesAvatarSize.large.rawValue, 48)
    }

    // MARK: - Compile contract

    func testEveryAvatarSizeCompiles() {
        for size in HermesAvatarSize.allCases {
            let avatar = HermexAvatar(systemImage: "person.fill", size: size)
            XCTAssertFalse(String(describing: type(of: avatar)).isEmpty)
        }
    }

    // MARK: - Source contract: Content Unavailable composes the Avatar instead of a raw Label icon

    func testContentUnavailableComposesHermexAvatarInsteadOfARawLabelIcon() throws {
        let src = try source("HermesMobile/Features/Shared/HermexContentUnavailable.swift")
        XCTAssertTrue(src.contains("HermexAvatar("), "Icon-bearing variants should compose HermexAvatar")
        XCTAssertFalse(src.contains("Label(title, systemImage: systemImage)"), "The raw Label icon treatment should be replaced")
    }

    func testLoadingVariantStaysASpinner() throws {
        let src = try source("HermesMobile/Features/Shared/HermexContentUnavailable.swift")
        XCTAssertTrue(src.contains("case .loading:\n            ProgressView()"))
    }
}
