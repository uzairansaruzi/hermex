import Foundation

enum PrivateNetworkProvider: String, CaseIterable, Identifiable {
    case tailscale = "Tailscale"
    case netBird = "NetBird"

    var id: Self { self }

    var setupPrompt: String {
        switch self {
        case .tailscale:
            return OnboardingFlowPolicy.tailscaleSetupPrompt
        case .netBird:
            return OnboardingFlowPolicy.netBirdSetupPrompt
        }
    }

    var appStoreURL: URL {
        switch self {
        case .tailscale:
            return URL(string: "itms-apps://apps.apple.com/us/app/tailscale/id1470499037")!
        case .netBird:
            return URL(string: "itms-apps://apps.apple.com/us/app/netbird-p2p-vpn/id6469329339")!
        }
    }

    var appStoreFallbackURL: URL {
        switch self {
        case .tailscale:
            return URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!
        case .netBird:
            return URL(string: "https://apps.apple.com/us/app/netbird-p2p-vpn/id6469329339")!
        }
    }

    var iphoneSetupSteps: [String] {
        switch self {
        case .tailscale:
            return [
                String(localized: "Install Tailscale from the App Store."),
                String(localized: "Sign in with the same account you used on your server."),
                String(localized: "Keep Tailscale connected while using Hermex.")
            ]
        case .netBird:
            return [
                String(localized: "Install NetBird from the App Store."),
                String(localized: "Add the same NetBird account or management server used by your server."),
                String(localized: "Keep NetBird connected while using Hermex.")
            ]
        }
    }
}

enum OnboardingFlowPolicy {
    static let pageCount = 5
    static let connectPageIndex = 4
    static let agentPromptPageIndex = 2

    static let tailscaleSetupPrompt = """
Set up Hermes Web UI on this machine for access from my iPhone via Tailscale.

Clone and install https://github.com/nesquena/hermes-webui. Follow its current installation instructions and start it on port 8787.
Enable password authentication by setting the HERMES_WEBUI_PASSWORD environment variable. Generate a secure random password and save it — I'll need it for the iPhone app.
Install Tailscale on this machine. Search the web for the correct install method for this OS if you're unsure. Authenticate to my Tailscale account — if this requires opening a URL or an auth key, tell me exactly what to do.
Make the WebUI reachable over Tailscale:
- Try tailscale serve --bg 8787 first (gives HTTPS + nice hostname).
- If Tailscale Serve is disabled on my tailnet, fall back: bind the server to 0.0.0.0 instead of localhost so it listens on the tailnet interface. Before doing this, confirm password auth is active — never expose an unauthenticated WebUI.
Set up auto-start appropriate for this OS so the WebUI survives reboots.
Verify it works: curl http://$(tailscale ip -4):8787/health should return a success response.
Reply with:
- The exact server URL I enter in Hermex
- The password
- Any setup steps I still need to do on my iPhone
Do not use Cloudflare. Optimize for Tailscale + iPhone.
"""

    static let netBirdSetupPrompt = """
Set up Hermes Web UI on this machine for access from my iPhone via NetBird.

Clone and install https://github.com/nesquena/hermes-webui. Follow its current installation instructions and start it on port 8787.
Enable password authentication by setting the HERMES_WEBUI_PASSWORD environment variable. Generate a secure random password and save it — I'll need it for the iPhone app.
Install NetBird on this machine using the current official instructions for this OS. Connect it to my NetBird network with `netbird up`. If authentication requires a browser login, setup key, or self-hosted management URL, tell me exactly what I need to provide or do; do not guess credentials.
Make the WebUI reachable over NetBird:
- Bind the server to 0.0.0.0 instead of localhost so it listens on the NetBird interface. Before doing this, confirm password auth is active — never expose an unauthenticated WebUI.
- Check the host firewall and NetBird access policy. Allow my iPhone peer to reach TCP port 8787, but do not expose the port publicly. If you cannot change my NetBird policy, give me the exact policy change I need to make.
Set up auto-start appropriate for this OS so the WebUI and NetBird survive reboots.
Verify it works: find the server's NetBird IPv4 address using `netbird status` or `ip addr show wt0`, then run `curl http://<netbird-ip>:8787/health` with that address. It should return a success response.
Reply with:
- The exact server URL I enter in Hermex
- The password
- Any setup steps I still need to do on my iPhone
Do not use Cloudflare. Optimize for NetBird + iPhone.
"""

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
