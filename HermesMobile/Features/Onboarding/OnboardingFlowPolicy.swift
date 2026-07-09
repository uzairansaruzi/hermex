import Foundation

enum OnboardingFlowPolicy {
    static let pageCount = 5
    static let connectPageIndex = 4
    static let agentPromptPageIndex = 2

    static let agentSetupPrompt = """
Set up Hermes Web UI on this machine for access from my iPhone via Tailscale.

Clone and install https://github.com/nesquena/hermes-webui — it's a Node.js web app. Install dependencies and start it on port 8787.
Enable password authentication by setting the HERMES_WEBUI_PASSWORD environment variable. Generate a secure random password and save it — I'll need it for the iPhone app.
Install Tailscale on this machine. Search the web for the correct install method for this OS if you're unsure. Authenticate to my Tailscale account — if this requires opening a URL or an auth key, tell me exactly what to do.
Make the WebUI reachable over Tailscale:
- First check if anything is already running on port 443: `tailscale serve status`. If a service is already on 443, use `tailscale serve --bg --https=8787 127.0.0.1:8787` instead.
- Try `tailscale serve --bg --https=8787 127.0.0.1:8787` (uses dedicated port 8787 so it never silently clobbers existing services on port 443).
- If Tailscale Serve is disabled on my tailnet, fall back: bind the server to 0.0.0.0 instead of localhost so it listens on the tailnet interface. Before doing this, confirm password auth is active — never expose an unauthenticated WebUI.
Set up auto-start appropriate for this OS so the WebUI survives reboots.
Verify it works: curl http://$(tailscale ip -4):8787/health should return a success response.
Reply with:
- The exact server URL I enter in Hermex
- The password
- Any setup steps I still need to do on my iPhone
Do not use Cloudflare. Optimize for Tailscale + iPhone.
"""

    static let tailscaleAppStoreURL = URL(string: "itms-apps://apps.apple.com/us/app/tailscale/id1470499037")!

    static let tailscaleAppStoreFallbackURL = URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!

    static func primaryButtonTitle(for page: Int) -> String {
        switch page {
        case 0:
            return String(localized: "Get Started")
        case 1:
            return String(localized: "Set Up")
        case connectPageIndex:
            return String(localized: "Connect")
        default:
            return String(localized: "Continue")
        }
    }

    static func shouldShowCopyReminder(
        page: Int,
        hasCopiedAgentPrompt: Bool,
        hasBypassedCopyReminder: Bool = false
    ) -> Bool {
        page == agentPromptPageIndex && !hasCopiedAgentPrompt && !hasBypassedCopyReminder
    }

    static func shouldInterceptForwardNavigationFromAgentPrompt(
        from oldPage: Int,
        to newPage: Int,
        hasCopiedAgentPrompt: Bool,
        hasBypassedCopyReminder: Bool = false
    ) -> Bool {
        oldPage == agentPromptPageIndex
            && newPage > oldPage
            && !hasCopiedAgentPrompt
            && !hasBypassedCopyReminder
    }

    static func shouldClearConnectFocusWhenLeavingPage(_ page: Int) -> Bool {
        page != connectPageIndex
    }

    static func showsServerShortcut(for page: Int) -> Bool {
        page < connectPageIndex
    }
}
