import XCTest
@testable import HermesMobile

final class ChatGitControlsVisibilityPolicyTests: XCTestCase {
    func testDisabledSettingHidesBothTurnEndGitSurfaces() {
        XCTAssertFalse(
            ChatGitControlsVisibilityPolicy.showsInlineCommitButton(
                showsGitControls: false,
                hasRepository: true,
                supportsWrites: true,
                isStreaming: false,
                latestMessageRole: "assistant",
                hasCommittableChanges: true,
                isCommitting: false
            )
        )
        XCTAssertFalse(
            ChatGitControlsVisibilityPolicy.showsTurnChangesRecap(
                showsGitControls: false,
                hasRepository: true,
                isStreaming: false,
                latestMessageRole: "assistant"
            )
        )
    }

    func testEnabledSettingPreservesInlineCommitConditions() {
        XCTAssertTrue(showsInlineCommit())
        XCTAssertFalse(showsInlineCommit(hasRepository: false))
        XCTAssertFalse(showsInlineCommit(isStreaming: true))
        XCTAssertFalse(showsInlineCommit(latestMessageRole: "user"))
        XCTAssertFalse(showsInlineCommit(hasCommittableChanges: false))
        XCTAssertTrue(showsInlineCommit(hasCommittableChanges: false, isCommitting: true))
    }

    /// A Hermes chat's repository is read-only (#1114): its turn still gets the changes recap,
    /// but never the commit button, even mid-commit.
    func testARepositoryWithoutWritesKeepsTheRecapAndHidesTheCommitButton() {
        XCTAssertFalse(showsInlineCommit(supportsWrites: false))
        XCTAssertFalse(showsInlineCommit(supportsWrites: false, isCommitting: true))
        XCTAssertTrue(showsTurnChangesRecap())
    }

    func testEnabledSettingPreservesTurnChangesRecapConditions() {
        XCTAssertTrue(showsTurnChangesRecap())
        XCTAssertFalse(showsTurnChangesRecap(hasRepository: false))
        XCTAssertFalse(showsTurnChangesRecap(isStreaming: true))
        XCTAssertFalse(showsTurnChangesRecap(latestMessageRole: "user"))
    }

    private func showsInlineCommit(
        hasRepository: Bool = true,
        supportsWrites: Bool = true,
        isStreaming: Bool = false,
        latestMessageRole: String? = "assistant",
        hasCommittableChanges: Bool = true,
        isCommitting: Bool = false
    ) -> Bool {
        ChatGitControlsVisibilityPolicy.showsInlineCommitButton(
            showsGitControls: true,
            hasRepository: hasRepository,
            supportsWrites: supportsWrites,
            isStreaming: isStreaming,
            latestMessageRole: latestMessageRole,
            hasCommittableChanges: hasCommittableChanges,
            isCommitting: isCommitting
        )
    }

    private func showsTurnChangesRecap(
        hasRepository: Bool = true,
        isStreaming: Bool = false,
        latestMessageRole: String? = "assistant"
    ) -> Bool {
        ChatGitControlsVisibilityPolicy.showsTurnChangesRecap(
            showsGitControls: true,
            hasRepository: hasRepository,
            isStreaming: isStreaming,
            latestMessageRole: latestMessageRole
        )
    }
}
