import Foundation

struct BotDestination: Equatable, Hashable {
    let server: URL
    let connectionID: UUID
    let profile: String
    var conversation: String?
    var opensScreen = false
}

extension HermesDeepLink {
    private static let connectionQueryItem = "connection"
    private static let conversationQueryItem = "conversation"
    private static let screenQueryItem = "screen"

    static func botURL(for destination: BotDestination) -> URL? {
        let profile = destination.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = botHost
        var items = [
            URLQueryItem(name: serverQueryItem, value: destination.server.absoluteString),
            URLQueryItem(name: connectionQueryItem, value: destination.connectionID.uuidString),
            URLQueryItem(name: profileQueryItem, value: profile)
        ]
        if let conversation = trimmed(destination.conversation) {
            items.append(URLQueryItem(name: conversationQueryItem, value: conversation))
        }
        if destination.opensScreen { items.append(URLQueryItem(name: screenQueryItem, value: "1")) }
        components.queryItems = items
        return components.url
    }

    static func botDestination(from url: URL) -> BotDestination? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == botHost else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            trimmed(items.first { $0.name == name }?.value)
        }

        guard let rawServer = value(serverQueryItem),
              let server = try? AuthManager.normalizedServerURL(from: rawServer),
              let connectionID = value(connectionQueryItem).flatMap(UUID.init(uuidString:)),
              let profile = value(profileQueryItem)
        else {
            return nil
        }

        return BotDestination(
            server: server,
            connectionID: connectionID,
            profile: profile,
            conversation: value(conversationQueryItem),
            opensScreen: value(screenQueryItem) == "1"
        )
    }

    private static func trimmed(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum BotDeepLinkOutcome: Equatable {
    case ignore
    case waitForSignIn(BotDestination)
    case switchServer(ServerAccount, BotDestination)
    case open(BotDestination)
}

@MainActor enum BotDeepLinkRouter {
    static func resolve(
        _ destination: BotDestination,
        state: AuthManager.State,
        servers: [ServerAccount],
        isBotModeEnabled: Bool,
        botConnectionID: @MainActor (URL) -> UUID? = savedConnectionID
    ) -> BotDeepLinkOutcome {
        guard let account = servers.first(where: { $0.id == destination.server.absoluteString }) else {
            return .ignore
        }
        guard isBotModeEnabled || account.kind == .hermes else { return .ignore }
        guard botConnectionID(destination.server) == destination.connectionID else { return .ignore }

        switch state {
        case .loggedIn(let active) where active == destination.server:
            return .open(destination)
        case .loggedIn:
            return .switchServer(account, destination)
        case .loggedOut, .unconfigured:
            return .waitForSignIn(destination)
        }
    }

    static func savedConnectionID(for server: URL) -> UUID? {
        (try? BotConnectionStore().load(server: server))?.id
    }

    static func inboxCanAnswer(link: BotInbox.Link, hasConnection: Bool, hasSettled: Bool) -> Bool {
        link == .live || (hasSettled && !hasConnection)
    }

    static func profile(
        for destination: BotDestination,
        connection: BotConnection?,
        profiles: [BotProfile]
    ) -> BotProfile? {
        guard let connection, connection.id == destination.connectionID else { return nil }
        return profiles.first { $0.id == destination.profile }
    }
}

struct BotInboxSelection {
    var profile: BotProfile? {
        didSet {
            if profile != nil { room = nil }
            conversation = nil
            pick = UUID()
            chatContinuity = ChatContinuity()
        }
    }
    var room: BotRoomKey? {
        didSet { if room != nil { profile = nil; conversation = nil }; pick = UUID() }
    }
    var conversation: String? {
        didSet { chatContinuity = ChatContinuity() }
    }
    private(set) var chatContinuity = ChatContinuity()
    private(set) var pick = UUID()

    @MainActor mutating func open(
        _ destination: BotDestination, connection: BotConnection?, profiles: [BotProfile]
    ) {
        profile = BotDeepLinkRouter.profile(for: destination, connection: connection, profiles: profiles)
        room = nil
        conversation = profile == nil ? nil : destination.conversation
    }

    func chat(server: URL, connection: BotConnection) -> HermesSessionChat? {
        profile.map {
            HermesSessionChat(server: server, connection: connection, target: .canonicalChat(profile: $0.id),
                              linkedRoot: conversation, bot: $0)
        }
    }
}
