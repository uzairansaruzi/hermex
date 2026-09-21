import Foundation

/// Turns a tapped relay banner into the conversation it is about. A tap only ever navigates:
/// an approval push lands on the conversation, where approving is its own deliberate
/// action.
@MainActor enum PushNotificationRouter {
    /// Webui taps use the pairing alone: neither Bot Mode nor a Bot connection is
    /// needed. A shared host alias prefers the active configured server.
    static func webuiDestination(
        userInfo: [AnyHashable: Any], pairings: [URL: PushPairing], activeServer: URL? = nil
    ) -> WebuiPushDestination? {
        let payload = PushPayload(userInfo: userInfo)
        guard payload.source == "webui",
              let id = payload.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let hash = payload.installHash,
              let server = pairings.filter({
                  PushPreviewKeys(installKey: $0.value.installKey, previewKey: $0.value.previewKey).installHash == hash
              }).keys.sorted(by: {
                  ($0 == activeServer ? 0 : 1, $0.absoluteString) < ($1 == activeServer ? 0 : 1, $1.absoluteString)
              }).first
        else { return nil }
        return WebuiPushDestination(server: server, sessionID: id)
    }

    /// Nil when the banner does not name a bot this phone can open: a webui or other
    /// source, a preview that never opened (the Profile lives inside it), a pairing
    /// that has since been wiped, or a server with no Bot connection. The app then
    /// simply opens. The pairing picks the server, so a tap can never land on a bot
    /// with the same Profile name under another server.
    ///
    /// One host reached through two configured servers (LAN and a tunnel, say) hands
    /// both the same install key. The tap then stays on `activeServer` when it is one
    /// of them, and otherwise takes the first by URL that has a Bot connection.
    ///
    /// The destination carries no conversation: the payload's `session_id` is the
    /// run's live session, not the bot's durable root, and a bot has one chat.
    static func botDestination(
        userInfo: [AnyHashable: Any],
        pairings: [URL: PushPairing],
        activeServer: URL? = nil,
        botConnectionID: @MainActor (URL) -> UUID? = { @MainActor url in
            (try? BotConnectionStore().load(server: url))?.id
        }
    ) -> BotDestination? {
        let payload = PushPayload(userInfo: userInfo)
        guard payload.source == "bot",
              let profile = payload.profile, !profile.isEmpty,
              let installHash = payload.installHash
        else { return nil }
        let servers = pairings
            .filter { PushPreviewKeys(installKey: $0.value.installKey, previewKey: $0.value.previewKey).installHash == installHash }
            .keys
            .sorted { ($0 == activeServer ? 0 : 1, $0.absoluteString) < ($1 == activeServer ? 0 : 1, $1.absoluteString) }
        for server in servers {
            if let connectionID = botConnectionID(server) {
                return BotDestination(server: server, connectionID: connectionID, profile: profile)
            }
        }
        return nil
    }
}

/// Held across sign-in and server switching; consumed only by the owning session list.
struct WebuiPushDestination: Hashable {
    let server: URL
    let sessionID: String

    var url: URL? {
        var components = URLComponents()
        components.scheme = HermesDeepLink.scheme
        components.host = "webui-push"
        components.queryItems = [
            URLQueryItem(name: "server", value: server.absoluteString),
            URLQueryItem(name: "id", value: sessionID)
        ]
        return components.url
    }

    init(server: URL, sessionID: String) {
        self.server = server
        self.sessionID = sessionID
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == HermesDeepLink.scheme.lowercased(), url.host?.lowercased() == "webui-push",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawServer = items.first(where: { $0.name == "server" })?.value,
              let server = try? AuthManager.normalizedServerURL(from: rawServer),
              let id = items.first(where: { $0.name == "id" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        self.init(server: server, sessionID: id)
    }

    enum Route: Equatable {
        case ignore, waitForSignIn, open
        case switchServer(ServerAccount)
    }

    @MainActor func route(state: AuthManager.State, servers: [ServerAccount]) -> Route {
        guard let account = servers.first(where: { $0.id == server.absoluteString }) else { return .ignore }
        // Switch even from another server's login screen. Credentials are never
        // requested or looked up against a different server to resolve this session.
        guard state.server == server else { return .switchServer(account) }
        if case .loggedIn = state { return .open }
        return .waitForSignIn
    }
}
