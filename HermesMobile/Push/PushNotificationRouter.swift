import SwiftUI
import UserNotifications

@MainActor enum PushNotificationRouter {
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

    static func localAlertLink(userInfo: [AnyHashable: Any], servers: [ServerAccount]) -> URL? {
        let configured = servers.compactMap { URL(string: $0.id) }
        let removed = servers.flatMap(\.movedWebuiServers).compactMap { URL(string: $0.sourceServerID) }
            .filter { !configured.contains($0) }
        guard let link = ResponseCompletionNotificationRequest.destination(userInfo: userInfo, servers: configured + removed)
        else { return nil }
        guard let webui = WebuiPushDestination(url: link) else { return link }
        return WebuiPushDestination(server: webui.server, sessionID: webui.sessionID, opensOnSource: true).url
    }

    private static func hermesDestination(userInfo: [AnyHashable: Any], server: URL) -> HermesSessionDestination? {
        let payload = PushPayload(userInfo: userInfo)
        guard payload.source != "webui", let key = HermesDeepLink.normalizedSessionID(payload.sessionID) else { return nil }
        return HermesSessionDestination(server: server, profile: payload.profile, key: key,
                                        opensParent: userInfo["is_subagent"] as? Bool == true)
    }

    private static func servers(pairedWith installHash: String?, in pairings: [URL: PushPairing],
                                activeServer: URL?) -> [URL] {
        guard let installHash else { return [] }
        return pairings
            .filter { PushPreviewKeys(installKey: $0.value.installKey, previewKey: $0.value.previewKey).installHash == installHash }
            .keys
            .sorted { ($0 == activeServer ? 0 : 1, $0.absoluteString) < ($1 == activeServer ? 0 : 1, $1.absoluteString) }
    }

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

struct WebuiPushDestination: Hashable {
    let server: URL
    let sessionID: String
    let opensOnSource: Bool

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
        guard state.server == server else { return .switchServer(account) }
        if case .loggedIn = state { return .open }
        return .waitForSignIn
    }
}

@MainActor final class PushPresence {
    static let shared = PushPresence(appLock: .shared)

    private let appLock: AppLock

    init(appLock: AppLock) {
        self.appLock = appLock
    }

    struct Viewer: Hashable {
        let server: URL
        let sessionID: String
    }

    static let attentionKinds: Set<String> = ["approval", "clarify", "input", "turn_error"]

    private var entry: (owner: UUID, viewer: Viewer)?
    var viewer: Viewer? { appLock.isLocked ? nil : entry?.viewer }

    func enter(_ viewer: Viewer, owner: UUID) { entry = (owner, viewer) }

    func leave(owner: UUID) {
        if entry?.owner == owner { entry = nil }
    }

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
                if isVisible { record(viewer) }
            }
    }

    private func record(_ viewer: PushPresence.Viewer?) {
        if let viewer { PushPresence.shared.enter(viewer, owner: owner) }
        else { PushPresence.shared.leave(owner: owner) }
    }
}
