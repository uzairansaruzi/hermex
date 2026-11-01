import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for the shared static skeleton/redaction primitive (`SkeletonPlaceholder.swift`): the
/// `.redacted(reason: .placeholder)` treatment and its "announce once" accessibility grouping. A
/// SwiftUI view tree isn't inspectable at runtime without a rendering harness, so these are compile
/// contracts (the modifiers apply to a real View without error) plus a source contract read from
/// `SkeletonPlaceholder.swift` itself.
final class SkeletonPlaceholderTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HermesMobileTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    // MARK: - Compile contracts

    func testSkeletonPlaceholderCompilesOnAnyView() {
        let view = Text("Loading").skeletonPlaceholder()
        XCTAssertFalse(String(describing: type(of: view)).isEmpty)
    }

    func testSkeletonAnnouncementCompilesWithAndWithoutAValue() {
        let withoutValue = Text("Loading").skeletonAnnouncement(label: Text("Loading messages"))
        let withValue = Text("Loading").skeletonAnnouncement(label: Text("Limits"), value: Text("Loading"))
        XCTAssertFalse(String(describing: type(of: withoutValue)).isEmpty)
        XCTAssertFalse(String(describing: type(of: withValue)).isEmpty)
    }

    // MARK: - Source contract: the primitive itself

    func testPrimitiveAppliesRedactedPlaceholderAndOwnsTheAnnouncementGroupingWithNoAnimation() throws {
        let src = try source("HermesMobile/Features/Shared/SkeletonPlaceholder.swift")
        XCTAssertTrue(src.contains("func skeletonPlaceholder()"))
        XCTAssertTrue(src.contains("func skeletonAnnouncement("))
        XCTAssertTrue(src.contains(".redacted(reason: .placeholder)"))
        XCTAssertTrue(src.contains("accessibilityElement(children: .ignore)"))
        XCTAssertFalse(src.contains("Animation"), "the static primitive must introduce no animation")
        XCTAssertFalse(src.contains("withAnimation"), "the static primitive must introduce no animation")
    }

}
