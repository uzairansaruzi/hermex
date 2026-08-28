import XCTest
@testable import HermesMobile

final class ChatPerformanceFixtureTests: XCTestCase {
    func testCatalogIDsAreUniqueAndDimensionsAreComplete() {
        XCTAssertEqual(ChatPerformanceFixture.catalog.count, 648)
        XCTAssertEqual(
            Set(ChatPerformanceFixture.catalog.map(\.id)).count,
            ChatPerformanceFixture.catalog.count
        )
        XCTAssertEqual(
            Set(ChatPerformanceFixture.catalog.map(\.rowCount)),
            Set(ChatPerformanceFixture.rowCounts)
        )
        XCTAssertEqual(
            Set(ChatPerformanceFixture.catalog.map(\.responseBytes)),
            Set(ChatPerformanceFixture.responseByteLengths)
        )
    }

    func testCatalogCoversLoadedRowsAndExactResponseSizes() {
        for rowCount in ChatPerformanceFixture.rowCounts {
            for responseBytes in ChatPerformanceFixture.responseByteLengths {
                let fixture = ChatPerformanceFixture.make(
                    rowCount: rowCount,
                    responseBytes: responseBytes,
                    contentKind: .plain
                )
                XCTAssertEqual(fixture.messages.count, rowCount)
                XCTAssertEqual(fixture.response.count, responseBytes)
            }
        }
    }

    func testCatalogCoversContentToolScrollAndAnimationDimensions() {
        for contentKind in ChatPerformanceContentKind.allCases {
            for toolState in ChatPerformanceToolState.allCases {
                let fixture = ChatPerformanceFixture.make(
                    rowCount: 50,
                    responseBytes: 4_096,
                    contentKind: contentKind,
                    toolState: toolState,
                    followsScroll: false,
                    animationEnabled: true
                )
                XCTAssertEqual(fixture.scenario.contentKind, contentKind)
                XCTAssertEqual(fixture.scenario.toolState, toolState)
                XCTAssertFalse(fixture.scenario.followsScroll)
                XCTAssertTrue(fixture.scenario.animationEnabled)
                XCTAssertFalse(fixture.scenario.id.isEmpty)
            }
        }
    }

    func testFixtureMessageIDsAndOrderAreStable() {
        let first = ChatPerformanceFixture.make(
            rowCount: 200,
            responseBytes: 4_096,
            contentKind: .markdown
        )
        let second = ChatPerformanceFixture.make(
            rowCount: 200,
            responseBytes: 4_096,
            contentKind: .markdown
        )

        XCTAssertEqual(first.messages.map(\.id), second.messages.map(\.id))
        XCTAssertEqual(first.messages.map(\.id), first.messages.map(\.id).sorted { lhs, rhs in
            let left = Int(lhs.split(separator: "-").last!)!
            let right = Int(rhs.split(separator: "-").last!)!
            return left < right
        })
    }

    func testCompletedResponsePrefixIsByteIdenticalAcrossLargerFixtures() {
        let baseline = ChatPerformanceFixture.make(
            rowCount: 50,
            responseBytes: 4_096,
            contentKind: .plain
        )
        let larger = ChatPerformanceFixture.make(
            rowCount: 500,
            responseBytes: 65_536,
            contentKind: .plain
        )

        XCTAssertEqual(
            Data(larger.response.prefix(baseline.response.count)),
            baseline.response
        )
    }
}
