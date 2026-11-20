import XCTest
@testable import HermesMobile

final class OnboardingFlowTests: XCTestCase {
    func testCopyReminderOnlyAppliesToAgentPromptPageWithoutCopy() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: [],
                bypassedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
    }

    func testSetupEndsOnTheAddServerSheet() {
        let next = OnboardingFlowPolicy.page(after: OnboardingFlowPolicy.agentPromptPageIndex)
        XCTAssertEqual(next, 1)
        XCTAssertNil(OnboardingFlowPolicy.page(after: 1))
    }

    func testCopyReminderFollowsThePromptShown() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: [.webUI]
            )
        )
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .webUI,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .webUI,
                copiedPrompts: [.hermes, .webUI]
            )
        )
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .webUI,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .webUI,
                copiedPrompts: [.webUI]
            )
        )
    }

    func testForwardSwipeFromAgentPromptRequiresCopyOrBypass() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .hermes,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .hermes,
                copiedPrompts: [],
                bypassedPrompts: [.hermes]
            )
        )
    }

    func testSkippingOnePromptsReminderStillRemindsForTheOther() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                shownPrompt: .webUI,
                copiedPrompts: [],
                bypassedPrompts: [.hermes]
            )
        )
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: OnboardingFlowPolicy.agentPromptPageIndex + 1,
                shownPrompt: .webUI,
                copiedPrompts: [],
                bypassedPrompts: [.hermes]
            )
        )
    }

    func testWebUISetupPromptKeepsItsSafetyRules() {
        let prompt = OnboardingFlowPolicy.webUISetupPrompt

        for rule in [
            "Never enable Funnel",
            "Do not kill an unknown process",
            "Do not run tailscale serve reset",
            "never truncate or replace the file",
            "Do not print the full .env",
            "Do not automate it"
        ] {
            XCTAssertTrue(prompt.contains(rule), "Missing safety rule: \(rule)")
        }
        XCTAssertFalse(prompt.contains("fall back: bind the server to 0.0.0.0"))
    }

    func testHermesSetupPromptKeepsItsSafetyRules() {
        let prompt = OnboardingFlowPolicy.hermesSetupPrompt

        for rule in ["Do not kill an unknown process", "Never run the dashboard without its sign-in gate"] {
            XCTAssertTrue(prompt.contains(rule), "Missing safety rule: \(rule)")
        }
        XCTAssertFalse(prompt.contains("--insecure"))
    }
}
