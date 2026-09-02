import XCTest
@testable import HermesMobile

final class ChatHapticsTests: XCTestCase {
    @MainActor
    func testHapticsRespectEnabledSetting() {
        var feedback: [ChatHapticFeedback] = []

        ChatHaptics.messageSent(isEnabled: false) { feedback.append($0) }
        ChatHaptics.assistantResponseCompleted(isEnabled: false) { feedback.append($0) }
        ChatHaptics.streamCancelled(isEnabled: false) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.deny, isEnabled: false) { feedback.append($0) }
        ChatHaptics.clarificationSubmitted(isEnabled: false) { feedback.append($0) }
        ChatHaptics.configurationSelected(isEnabled: false) { feedback.append($0) }
        ChatHaptics.destructiveConfirmationAccepted(isEnabled: false) { feedback.append($0) }
        ChatHaptics.disclosureToggled(isEnabled: false) { feedback.append($0) }
        ChatHaptics.scrolledToLatest(isEnabled: false) { feedback.append($0) }
        ChatHaptics.copied(isEnabled: false) { feedback.append($0) }
        ChatHaptics.gitActionFinished(succeeded: true, isEnabled: false) { feedback.append($0) }
        ChatHaptics.streamingPulse(isEnabled: false) { feedback.append($0) }

        XCTAssertTrue(feedback.isEmpty)
    }

    @MainActor
    func testChatDecisionHapticLanguage() {
        var feedback: [ChatHapticFeedback] = []

        ChatHaptics.messageSent(isEnabled: true) { feedback.append($0) }
        ChatHaptics.assistantResponseCompleted(isEnabled: true) { feedback.append($0) }
        ChatHaptics.streamCancelled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.once, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.session, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.always, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.deny, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalBypassEnabled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.clarificationSubmitted(isEnabled: true) { feedback.append($0) }
        ChatHaptics.configurationSelected(isEnabled: true) { feedback.append($0) }
        ChatHaptics.destructiveConfirmationAccepted(isEnabled: true) { feedback.append($0) }
        ChatHaptics.disclosureToggled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.scrolledToLatest(isEnabled: true) { feedback.append($0) }
        ChatHaptics.copied(isEnabled: true) { feedback.append($0) }
        ChatHaptics.gitActionFinished(succeeded: true, isEnabled: true) { feedback.append($0) }
        ChatHaptics.gitActionFinished(succeeded: false, isEnabled: true) { feedback.append($0) }
        ChatHaptics.streamingPulse(isEnabled: true) { feedback.append($0) }

        XCTAssertEqual(feedback, [
            .lightImpact,
            .success,
            .mediumImpact,
            .lightImpact,
            .lightImpact,
            .lightImpact,
            .warning,
            .warning,
            .selection,
            .selection,
            .warning,
            .selection,
            .selection,
            .lightImpact,
            .success,
            .warning,
            .selection
        ])
    }

    func testStreamingPulseThrottleAllowsOneTickPerInterval() {
        var throttle = ChatHaptics.StreamingPulseThrottle()

        XCTAssertTrue(throttle.shouldPulse(at: 10.0), "first token pulses immediately")
        XCTAssertFalse(throttle.shouldPulse(at: 10.1))
        XCTAssertFalse(throttle.shouldPulse(at: 10.31), "just under the 320 ms window stays quiet")
        XCTAssertTrue(throttle.shouldPulse(at: 10.32))
        XCTAssertFalse(throttle.shouldPulse(at: 10.5), "the window restarts from the last pulse, not the last token")

        throttle.reset()
        XCTAssertTrue(throttle.shouldPulse(at: 10.51), "reset makes the next token pulse again")
    }

    /// The pulse trigger bumps on the first live token, stays quiet inside the
    /// throttle window, and re-arms when the next connection starts so a fast
    /// follow-up reply still ticks on its first token.
    @MainActor
    func testStreamingPulseTriggerReArmsPerConnection() {
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "session-1"),
            server: URL(string: "https://example.test")!
        )

        viewModel.streamCoordinatorDidStartConnection(isReplay: false)
        XCTAssertTrue(viewModel.streamCoordinatorAppendToken("Hello"))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 1)
        XCTAssertTrue(viewModel.streamCoordinatorAppendToken(" world"))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 1, "second token inside the window stays quiet")

        viewModel.streamCoordinatorDidStartConnection(isReplay: false)
        XCTAssertTrue(viewModel.streamCoordinatorAppendToken("Again"))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 2, "a new connection re-arms the first pulse")

        viewModel.streamCoordinatorDidStartConnection(isReplay: true)
        XCTAssertTrue(viewModel.streamCoordinatorAppendToken(" continued"))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 2, "a replay continues the same reply and keeps its window")
    }

    @MainActor
    func testConfigurationNoOpSelectionsDoNotReportSuccess() async {
        let viewModel = ChatViewModel(
            session: SessionSummary(
                sessionId: "session-1",
                workspace: "/tmp/project",
                model: "gpt-5",
                modelProvider: "openai",
                profile: "work"
            ),
            server: URL(string: "https://example.test")!
        )

        let didSelectCurrentModel = await viewModel.selectComposerModel(ModelCatalogOption(
            id: "gpt-5",
            displayName: "GPT-5",
            providerID: "openai"
        ))
        let didSelectCurrentWorkspace = await viewModel.selectWorkspacePath(" /tmp/project ")
        let didSelectCurrentProfile = await viewModel.switchProfile(
            ProfileSummary(
                name: "work",
                path: nil,
                isDefault: nil,
                isActive: true,
                gatewayRunning: nil,
                model: nil,
                provider: nil,
                hasEnv: nil,
                skillCount: nil
            ),
            startNewSession: false
        )

        XCTAssertFalse(didSelectCurrentModel)
        XCTAssertFalse(didSelectCurrentWorkspace)
        XCTAssertNil(didSelectCurrentProfile)
    }
}
