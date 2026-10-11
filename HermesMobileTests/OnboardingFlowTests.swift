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
                hasBypassedCopyReminder: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.connectPageIndex,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
    }

    func testCopyReminderFollowsThePromptShown() {
        // Copying one prompt and then swapping to the other still needs a copy.
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
                to: 3,
                shownPrompt: .webUI,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                shownPrompt: .webUI,
                copiedPrompts: [.webUI]
            )
        )
    }

    func testForwardSwipeFromAgentPromptRequiresCopyOrBypass() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                shownPrompt: .hermes,
                copiedPrompts: [.hermes]
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                shownPrompt: .hermes,
                copiedPrompts: [],
                hasBypassedCopyReminder: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 1,
                shownPrompt: .hermes,
                copiedPrompts: []
            )
        )
    }

    func testStepOneOpensOnTheHermesPromptAndSwapsToWebUIAndBack() {
        let initial = OnboardingFlowPolicy.initialSetupPrompt
        XCTAssertEqual(initial, .hermes)
        XCTAssertEqual(initial.text, OnboardingFlowPolicy.hermesSetupPrompt)
        XCTAssertEqual(initial.title, "Set up Hermes")
        XCTAssertEqual(initial.switchTitle, "Using Hermes Web UI instead?")

        let swapped = initial.alternative
        XCTAssertEqual(swapped, .webUI)
        XCTAssertEqual(swapped.text, OnboardingFlowPolicy.webUISetupPrompt)
        XCTAssertEqual(swapped.title, "Set up Hermes Web UI")
        XCTAssertEqual(swapped.alternative, .hermes)
    }

    func testSetupPromptChoiceKeepsThePageCount() {
        XCTAssertEqual(OnboardingFlowPolicy.pageCount, 5)
        XCTAssertEqual(OnboardingFlowPolicy.agentPromptPageIndex, 2)
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

    func testAgentSetupPromptDefaultsToSafeStateAwareTailscaleServe() {
        let prompt = OnboardingFlowPolicy.webUISetupPrompt

        let requiredInstructions = [
            "Python standard library + vanilla JavaScript",
            "Inventory before changing anything",
            "command -v tailscale",
            "tailscale version",
            "tailscale status",
            "Only if `command -v tailscale` reports that Tailscale is absent",
            "correct method for this OS",
            "rerun `tailscale version`, `tailscale status`, and the authentication check",
            "tailscale serve status",
            "tailscale funnel status",
            "lsof -nP -iTCP:8787 -sTCP:LISTEN",
            "Do not kill an unknown process",
            "Do not run tailscale serve reset",
            "127.0.0.1:8787",
            "only if HTTPS port 443 at the root path is free",
            "tailscale serve --bg 8787",
            "Never enable Funnel",
            "HTTPS consent",
            "certificate-transparency disclosure",
            "umask 077",
            "chmod 600",
            "Preserve every existing line in `.env`",
            "only add or update the `HERMES_WEBUI_PASSWORD` entry",
            "never truncate or replace the file",
            "Whether `.env` already existed or is new",
            "Do not print the full .env",
            "python3 bootstrap.py",
            "./ctl.sh",
            "Do not configure auto-start yourself",
            "Propose the exact OS-appropriate commands and steps",
            "wait for me to run them",
            "Do not touch `~/Library/LaunchAgents/` or restart Mac services",
            "curl --fail http://127.0.0.1:8787/health",
            "actual ts.net HTTPS URL",
            "exact HTTPS URL, password, launcher, and both health-check results",
            "manual fallback",
            "Do not automate it"
        ]

        for instruction in requiredInstructions {
            XCTAssertTrue(prompt.contains(instruction), "Missing safe setup instruction: \(instruction)")
        }

        XCTAssertFalse(prompt.contains("Node.js"))
        XCTAssertFalse(prompt.contains("curl http://$(tailscale ip -4):8787/health"))
        XCTAssertFalse(prompt.contains("fall back: bind the server to 0.0.0.0"))
        XCTAssertFalse(prompt.contains("Otherwise configure auto-start appropriate for this OS"))
    }

    func testHermesSetupPromptRequiresSignInPersistentSecretAndPublicURL() {
        let prompt = OnboardingFlowPolicy.hermesSetupPrompt

        let requiredInstructions = [
            "Set up the Hermes dashboard on this machine for access from my iPhone.",
            "Inventory before changing anything",
            "`hermes dashboard`",
            "default 9119",
            "config.yaml",
            "Do not kill an unknown process",
            "dashboard.basic_auth.username",
            "password_hash",
            "plugins.dashboard_auth.basic import hash_password",
            "dashboard.basic_auth.secret",
            "survive a restart",
            "dashboard.public_url",
            "400 Invalid Host header",
            "Cloudflare Tunnel",
            "Tailscale",
            "same Wi-Fi",
            "require my confirmation",
            "Never run the dashboard without its sign-in gate",
            "/api/status",
            "\"auth_required\": true",
            "address, username, password"
        ]

        for instruction in requiredInstructions {
            XCTAssertTrue(prompt.contains(instruction), "Missing Hermes setup instruction: \(instruction)")
        }

        XCTAssertFalse(prompt.contains("--insecure"))
        XCTAssertFalse(prompt.contains("hermes-webui"))
    }

    func testTailscaleAppStoreURLUsesITMSDeepLink() {
        XCTAssertEqual(
            OnboardingFlowPolicy.tailscaleAppStoreURL.absoluteString,
            "itms-apps://apps.apple.com/us/app/tailscale/id1470499037"
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.tailscaleAppStoreFallbackURL.absoluteString,
            "https://apps.apple.com/us/app/tailscale/id1470499037"
        )
    }

    func testConnectPageIndexIsFinalPagerPage() {
        XCTAssertEqual(OnboardingFlowPolicy.connectPageIndex, OnboardingFlowPolicy.pageCount - 1)
    }
}
