import SwiftUI
import UserNotifications

/// Turns a tapped relay banner into the conversation it is about. A tap only ever navigates:
/// an approval push lands on the conversation, where approving is its own deliberate
/// action.
@MainActor enum PushNotificationRouter {
    /// The deep link a tapped relay banner queues on `AppIntentRouter`, or nil when it names
    /// nothing this phone can open and the app simply opens. A webui push opens its webui
    /// session on a webui server, or, once that server moved to Hermes and was removed, on the
    /// Hermes server its pairing passed to (#1217). Any other push goes to the first configured server holding its install, the active
    /// one first, then by URL, that can open it: a Hermes server opens the session through the
    /// session link (#1177), Bot Chats included, whose row opens their bot; a webui server opens
    /// its Bot connection's bot (legacy Bot Mode). One host under both kinds routes by the active one.
    static func link(
        userInfo: [AnyHashable: Any], pairings: [URL: PushPairing], servers: [ServerAccount], activeServer: URL? = nil,
        botConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID
    ) -> URL? {
        if let destination = webuiDestination(userInfo: userInfo, pairings: pairings, servers: servers,
                                              activeServer: activeServer) {
            return destination.url
        }
        if let moved = movedWebuiLink(userInfo: userInfo, pairings: pairings, servers: servers) {
            return moved
        }
        let payload = PushPayload(userInfo: userInfo)
        let kinds = Dictionary(servers.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        for server in self.servers(pairedWith: payload.installHash, in: pairings, activeServer: activeServer) {
            switch kinds[server.absoluteString] {
            case .hermes:
                if let destination = hermesDestination(userInfo: userInfo, server: server) {
                    return HermesDeepLink.sessionURL(for: destination)
                }
            case .webui:
                if let destination = botDestination(userInfo: userInfo, pairings: pairings.filter { $0.key == server },
                                                    botConnectionID: botConnectionID) {
                    return HermesDeepLink.botURL(for: destination)
                }
            case nil:
                continue
            }
        }
        return nil
    }

    /// Webui taps use the pairing alone: neither Bot Mode nor a Bot connection is
    /// needed. Only a configured webui server opens one, the active alias first, so a host
    /// also configured as a Hermes server never takes it there. The push is about a run on that
    /// server, so it opens there even after the server moved to Hermes (`opensOnSource`, #1217),
    /// where its live stream and approval card are.
    static func webuiDestination(
        userInfo: [AnyHashable: Any], pairings: [URL: PushPairing], servers: [ServerAccount], activeServer: URL? = nil
    ) -> WebuiPushDestination? {
        let payload = PushPayload(userInfo: userInfo)
        let webuiServers = Set(servers.filter { $0.kind == .webui }.map(\.id))
        guard payload.source == "webui",
              let id = HermesDeepLink.normalizedSessionID(payload.sessionID),
              let server = self.servers(pairedWith: payload.installHash, in: pairings, activeServer: activeServer)
                .first(where: { webuiServers.contains($0.absoluteString) })
        else { return nil }
        return WebuiPushDestination(server: server, sessionID: id, opensOnSource: true)
    }

    /// A webui push no configured webui server is paired for, after a same-host move (#1217): the
    /// Hermes server that copied the webui server's pairing holds its install and a move record,
    /// so the push opens there, looked up in every Profile, since the session's Profile on Hermes
    /// isn't the webui Profile a preview names. The pairing is the only proof: two such Hermes
    /// servers open nothing, and a cross-host move's old install is paired with nothing once its
    /// webui server is removed.
    private static func movedWebuiLink(userInfo: [AnyHashable: Any], pairings: [URL: PushPairing],
                                       servers: [ServerAccount]) -> URL? {
        let payload = PushPayload(userInfo: userInfo)
        let holders = Set(servers.filter { $0.kind == .hermes && !$0.movedWebuiServers.isEmpty }.map(\.id))
        guard payload.source == "webui", let key = HermesDeepLink.normalizedSessionID(payload.sessionID) else { return nil }
        let paired = self.servers(pairedWith: payload.installHash, in: pairings, activeServer: nil)
            .filter { holders.contains($0.absoluteString) }
        guard paired.count == 1, let server = paired.first else { return nil }
        return HermesDeepLink.sessionURL(for: HermesSessionDestination(server: server, profile: nil, key: key))
    }

    /// The link a tapped local run alert opens (`ResponseCompletionNotificationRequest`), or nil
    /// when it names no server this phone knows. A webui server that moved to Hermes and was
    /// removed (#1217) still counts, through the record its destination holds. A webui chat's
    /// alert is about a run on that server, so it opens there while it is configured, as a push
    /// does (`opensOnSource`).
    static func localAlertLink(userInfo: [AnyHashable: Any], servers: [ServerAccount]) -> URL? {
        let configured = servers.compactMap { URL(string: $0.id) }
        let removed = servers.flatMap(\.movedWebuiServers).compactMap { URL(string: $0.sourceServerID) }
            .filter { !configured.contains($0) }
        guard let link = ResponseCompletionNotificationRequest.destination(userInfo: userInfo, servers: configured + removed)
        else { return nil }
        guard let webui = WebuiPushDestination(url: link) else { return link }
        return WebuiPushDestination(server: webui.server, sessionID: webui.sessionID, opensOnSource: true).url
    }

    /// A non-webui push on Hermes server `server`: `session_id` is the session's stored key in
    /// every hook. The Profile is the one the opened preview wrote back, and nil with previews
    /// off (or for the default Profile, which the extension leaves out), when the lookup reads
    /// every Profile. A subagent's push asks for its parent.
    private static func hermesDestination(userInfo: [AnyHashable: Any], server: URL) -> HermesSessionDestination? {
        let payload = PushPayload(userInfo: userInfo)
        guard payload.source != "webui", let key = HermesDeepLink.normalizedSessionID(payload.sessionID) else { return nil }
        return HermesSessionDestination(server: server, profile: payload.profile, key: key,
                                        opensParent: userInfo["is_subagent"] as? Bool == true)
    }

    /// The servers whose pairing is the banner's install: `activeServer` first, then by URL.
    private static func servers(pairedWith installHash: String?, in pairings: [URL: PushPairing],
                                activeServer: URL?) -> [URL] {
        guard let installHash else { return [] }
        return pairings
            .filter { PushPreviewKeys(installKey: $0.value.installKey, previewKey: $0.value.previewKey).installHash == installHash }
            .keys
            .sorted { ($0 == activeServer ? 0 : 1, $0.absoluteString) < ($1 == activeServer ? 0 : 1, $1.absoluteString) }
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
    /// run's live session, not the bot's durable root, and a bot has one chat. `link` asks
    /// with one webui server's pairing at a time; a Hermes server's push opens its session instead.
    static func botDestination(
        userInfo: [AnyHashable: Any],
        pairings: [URL: PushPairing],
        activeServer: URL? = nil,
        botConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID
    ) -> BotDestination? {
        let payload = PushPayload(userInfo: userInfo)
        guard payload.source == "bot",
              let profile = payload.profile, !profile.isEmpty
        else { return nil }
        for server in servers(pairedWith: payload.installHash, in: pairings, activeServer: activeServer) {
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
    /// The link names a run on `server` (a relay push, a local run alert, a Live Activity's tap)
    /// or the Hermes list's fallback (#1217), so it opens on `server` while it is configured, even
    /// after the server moved to Hermes. Any other webui link on a moved server opens on its
    /// destination first (`MovedWebuiRoute`).
    let opensOnSource: Bool

    /// The query item carrying `opensOnSource`.
    static let onSourceQueryItem = "onSource"

    var url: URL? {
        guard let url = HermesDeepLink.webuiSessionURL(server: server, sessionID: sessionID) else { return nil }
        guard opensOnSource, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: Self.onSourceQueryItem, value: "1")]
        return components.url
    }

    init(server: URL, sessionID: String, opensOnSource: Bool = false) {
        self.server = server
        self.sessionID = sessionID
        self.opensOnSource = opensOnSource
    }

    /// A Live Activity's tap carries its `activity` and opens on its source like a push.
    init?(url: URL) {
        guard url.scheme?.lowercased() == HermesDeepLink.scheme.lowercased(), url.host?.lowercased() == "webui-push",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawServer = items.first(where: { $0.name == "server" })?.value,
              let server = try? AuthManager.normalizedServerURL(from: rawServer),
              let id = items.first(where: { $0.name == "id" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        let onSource = items.contains { $0.name == Self.onSourceQueryItem && $0.value == "1" }
        self.init(server: server, sessionID: id,
                  opensOnSource: onSource || AgentRunTapTarget.activityID(from: url) != nil)
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

/// The conversation on screen, and what a relay push may show while the app is open
/// (#566). Chat screens report themselves; `PushAppDelegate` asks `presentation`
/// when a push arrives in the foreground.
@MainActor final class PushPresence {
    static let shared = PushPresence(appLock: .shared)

    private let appLock: AppLock

    init(appLock: AppLock) {
        self.appLock = appLock
    }

    struct Viewer: Hashable {
        let server: URL
        /// The session the plugin reports under: a webui session's own ID, or a
        /// Hermes session's current stored key (`ChatViewModel.pushPresence`).
        let sessionID: String
    }

    /// Kinds that ask something of the user. They show even over their own conversation.
    static let attentionKinds: Set<String> = ["approval", "clarify", "input", "turn_error"]

    private var entry: (owner: UUID, viewer: Viewer)?
    /// None while the app lock hides the screen, so its chat's banners still show (#885).
    var viewer: Viewer? { appLock.isLocked ? nil : entry?.viewer }

    func enter(_ viewer: Viewer, owner: UUID) { entry = (owner, viewer) }

    /// Only the screen that entered can clear it, so an old chat disappearing after
    /// its replacement appeared, even one for the same conversation, leaves the new
    /// one on record.
    func leave(owner: UUID) {
        if entry?.owner == owner { entry = nil }
    }

    /// A relay push shows as a banner unless it is about `viewer`'s conversation,
    /// asks nothing of the user, and that server has presence suppression on.
    /// Anything else, such as a local completion alert or a push from an install
    /// no longer paired, keeps the system default of showing nothing in the foreground.
    static func presentation(
        userInfo: [AnyHashable: Any], viewer: Viewer?, pairings: [URL: PushPairing]
    ) -> UNNotificationPresentationOptions {
        let payload = PushPayload(userInfo: userInfo)
        guard let hash = payload.installHash else { return [] }
        let servers = pairings.filter {
            PushPreviewKeys(installKey: $0.value.installKey, previewKey: $0.value.previewKey).installHash == hash
        }
        guard !servers.isEmpty else { return [] }
        if let viewer, viewer.sessionID == payload.sessionID,
           servers[viewer.server]?.effectivePreferences.presenceSuppression == true,
           !attentionKinds.contains(payload.kind ?? "") {
            return []
        }
        return [.banner, .list, .sound]
    }
}

extension View {
    /// Records `viewer` as the conversation on screen while this view is visible.
    func pushPresence(_ viewer: PushPresence.Viewer?) -> some View {
        modifier(PushPresenceModifier(viewer: viewer))
    }
}

private struct PushPresenceModifier: ViewModifier {
    let viewer: PushPresence.Viewer?
    @State private var owner = UUID()
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                record(viewer)
            }
            .onDisappear {
                isVisible = false
                PushPresence.shared.leave(owner: owner)
            }
            .onChange(of: viewer) {
                // A Hermes session's stored key can arrive after the screen or move mid-turn.
                if isVisible { record(viewer) }
            }
    }

    private func record(_ viewer: PushPresence.Viewer?) {
        if let viewer { PushPresence.shared.enter(viewer, owner: owner) }
        else { PushPresence.shared.leave(owner: owner) }
    }
}
