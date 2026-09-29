import XCTest
@testable import HermesMobile

/// Only chats made by Fork From Here or `/branch` carry a "Forked from" row,
/// titled from the parent the session list cached.
final class ForkOriginTests: XCTestCase {
    private let fork = SessionSummary(sessionId: "child", sessionSource: "fork", parentSessionId: "parent")

    func testAChatThatIsNotAForkHasNoOrigin() {
        let chat = SessionSummary(sessionId: "chat", sessionSource: "webui")

        XCTAssertNil(ForkOrigin.resolve(session: chat, parent: nil))
    }

    func testAForkWithACachedParentUsesTheParentsListTitle() {
        let parent = SessionSummary(sessionId: "parent", title: "  Design review\n")

        let origin = ForkOrigin.resolve(session: fork, parent: parent)

        XCTAssertEqual(origin?.parentSessionID, "parent")
        XCTAssertEqual(origin?.parent?.sessionId, "parent")
        XCTAssertEqual(origin?.title, "Forked from Design review")
    }

    func testAnUntitledParentReadsUntitledSession() {
        let parent = SessionSummary(sessionId: "parent", title: " ")

        XCTAssertEqual(ForkOrigin.resolve(session: fork, parent: parent)?.title, "Forked from Untitled Session")
    }

    func testAForkWhoseParentIsNotCachedReadsTheFallback() {
        let origin = ForkOrigin.resolve(session: fork, parent: nil)

        XCTAssertEqual(origin?.parentSessionID, "parent")
        XCTAssertNil(origin?.parent)
        XCTAssertEqual(origin?.title, "Forked from another chat")
    }

    func testAChildSessionThatIsNotAForkHasNoOrigin() {
        let subagent = SessionSummary(
            sessionId: "child",
            sessionSource: "other",
            parentSessionId: "parent",
            relationshipType: "child_session"
        )

        XCTAssertNil(ForkOrigin.parentSessionID(of: subagent))
        XCTAssertNil(ForkOrigin.resolve(session: subagent, parent: nil))
    }

    func testAForkWithoutAParentIDHasNoOrigin() {
        let orphan = SessionSummary(sessionId: "child", sessionSource: "fork", parentSessionId: "  ")

        XCTAssertNil(ForkOrigin.resolve(session: orphan, parent: nil))
    }

    func testTheForkMarkerMatchesTheWebUIsNormalization() {
        let fork = SessionSummary(sessionId: "child", sessionSource: " Fork ", parentSessionId: " parent ")

        XCTAssertEqual(ForkOrigin.parentSessionID(of: fork), "parent")
    }
}
