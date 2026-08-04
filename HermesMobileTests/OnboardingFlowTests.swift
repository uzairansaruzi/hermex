import XCTest
@testable import HermesMobile

final class OnboardingFlowTests: XCTestCase {
    func testPrimaryButtonTitlesFollowPagerFlow() {
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 0), "Get Started")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 1), "Set Up")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 2), "Continue")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 3), "Continue")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 4), "Connect")
    }

    func testCopyReminderOnlyAppliesToAgentPromptPageWithoutCopy() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: false
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: false,
                hasBypassedCopyReminder: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.connectPageIndex,
                hasCopiedAgentPrompt: false
            )
        )
    }

    func testForwardSwipeFromAgentPromptRequiresCopyOrBypass() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: false
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: false,
                hasBypassedCopyReminder: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 1,
                hasCopiedAgentPrompt: false
            )
        )
    }

    func testConnectFocusClearsWhenLeavingConnectPage() {
        XCTAssertTrue(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(3))
        XCTAssertFalse(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(OnboardingFlowPolicy.connectPageIndex))
    }

    func testServerShortcutShowsBeforeConnectPageOnly() {
        XCTAssertTrue(OnboardingFlowPolicy.showsServerShortcut(for: 0))
        XCTAssertTrue(OnboardingFlowPolicy.showsServerShortcut(for: 3))
        XCTAssertFalse(OnboardingFlowPolicy.showsServerShortcut(for: OnboardingFlowPolicy.connectPageIndex))
    }

    func testTailscaleSetupPromptIncludesProviderRequirements() {
        let prompt = PrivateNetworkProvider.tailscale.setupPrompt

        XCTAssertTrue(prompt.contains("hermes-webui"))
        XCTAssertTrue(prompt.contains("HERMES_WEBUI_PASSWORD"))
        XCTAssertTrue(prompt.contains("tailscale serve --bg 8787"))
        XCTAssertTrue(prompt.contains("curl http://$(tailscale ip -4):8787/health"))
        XCTAssertTrue(prompt.contains("Do not use Cloudflare. Optimize for Tailscale + iPhone."))
        XCTAssertTrue(prompt.contains("Hermex"))
    }

    func testNetBirdSetupPromptIncludesProviderRequirements() {
        let prompt = PrivateNetworkProvider.netBird.setupPrompt

        XCTAssertTrue(prompt.contains("hermes-webui"))
        XCTAssertTrue(prompt.contains("HERMES_WEBUI_PASSWORD"))
        XCTAssertTrue(prompt.contains("netbird up"))
        XCTAssertTrue(prompt.contains("ip addr show wt0"))
        XCTAssertTrue(prompt.contains("curl http://<netbird-ip>:8787/health"))
        XCTAssertTrue(prompt.contains("NetBird access policy"))
        XCTAssertTrue(prompt.contains("Do not use Cloudflare. Optimize for NetBird + iPhone."))
        XCTAssertTrue(prompt.contains("Hermex"))
    }

    func testProviderAppStoreURLsUseITMSDeepLinks() {
        XCTAssertEqual(
            PrivateNetworkProvider.tailscale.appStoreURL.absoluteString,
            "itms-apps://apps.apple.com/us/app/tailscale/id1470499037"
        )
        XCTAssertEqual(
            PrivateNetworkProvider.tailscale.appStoreFallbackURL.absoluteString,
            "https://apps.apple.com/us/app/tailscale/id1470499037"
        )
        XCTAssertEqual(
            PrivateNetworkProvider.netBird.appStoreURL.absoluteString,
            "itms-apps://apps.apple.com/us/app/netbird-p2p-vpn/id6469329339"
        )
        XCTAssertEqual(
            PrivateNetworkProvider.netBird.appStoreFallbackURL.absoluteString,
            "https://apps.apple.com/us/app/netbird-p2p-vpn/id6469329339"
        )
    }

    func testProviderSetupStepsUseSelectedProvider() {
        XCTAssertTrue(PrivateNetworkProvider.tailscale.iphoneSetupSteps.joined().contains("Tailscale"))
        XCTAssertFalse(PrivateNetworkProvider.tailscale.iphoneSetupSteps.joined().contains("NetBird"))
        XCTAssertTrue(PrivateNetworkProvider.netBird.iphoneSetupSteps.joined().contains("NetBird"))
        XCTAssertFalse(PrivateNetworkProvider.netBird.iphoneSetupSteps.joined().contains("Tailscale"))
    }

    func testConnectPageIndexIsFinalPagerPage() {
        XCTAssertEqual(OnboardingFlowPolicy.connectPageIndex, OnboardingFlowPolicy.pageCount - 1)
    }
}
