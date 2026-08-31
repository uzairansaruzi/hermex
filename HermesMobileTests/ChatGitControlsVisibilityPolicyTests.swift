import XCTest
@testable import HermesMobile

final class ChatGitControlsVisibilityPolicyTests: XCTestCase {
    func testDisabledSettingHidesBothTurnEndGitSurfaces() {
        XCTAssertFalse(
            ChatGitControlsVisibilityPolicy.showsInlineCommitButton(
                showsGitControls: false,
                hasRepository: true,
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

    func testEnabledSettingPreservesTurnChangesRecapConditions() {
        XCTAssertTrue(showsTurnChangesRecap())
        XCTAssertFalse(showsTurnChangesRecap(hasRepository: false))
        XCTAssertFalse(showsTurnChangesRecap(isStreaming: true))
        XCTAssertFalse(showsTurnChangesRecap(latestMessageRole: "user"))
    }

    private func showsInlineCommit(
        hasRepository: Bool = true,
        isStreaming: Bool = false,
        latestMessageRole: String? = "assistant",
        hasCommittableChanges: Bool = true,
        isCommitting: Bool = false
    ) -> Bool {
        ChatGitControlsVisibilityPolicy.showsInlineCommitButton(
            showsGitControls: true,
            hasRepository: hasRepository,
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
