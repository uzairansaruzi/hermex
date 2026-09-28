import Foundation

/// Where an external event — today a deep link, later a push or a Live Activity tap —
/// wants the app to land inside Bot Mode. Identity only, never a display name: the
/// configured server owns the Bot connection, the connection UUID survives password
/// and name edits, and the Profile name is the server's own key for that bot.
/// `conversation` is the bot's durable canonical root when the sender knows it (#554).
struct BotDestination: Equatable, Hashable {
    let server: URL
    let connectionID: UUID
    let profile: String
    var conversation: String?
}

extension HermesDeepLink {
    private static let serverQueryItem = "server"
    private static let connectionQueryItem = "connection"
    private static let conversationQueryItem = "conversation"

    /// `hermes-agent://bot?server=…&connection=…&profile=…[&conversation=…]`, the one
    /// bot route (scheme follows the active build, e.g. `-branch`). Every part rides as
    /// a query item, like `newChatInProfileURL`, so a Profile name with spaces or
    /// non-ASCII is percent-encoded rather than mangled into the host.
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
        components.queryItems = items
        return components.url
    }

    /// Parses a bot route into its typed destination. Nil for any other kind of link and
    /// for one missing the identity needed to route without guessing — a link is dropped
    /// rather than opening the wrong bot.
    static func botDestination(from url: URL) -> BotDestination? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == botHost else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            trimmed(items.first { $0.name == name }?.value)
        }

        guard let rawServer = value(serverQueryItem),
              // The registry stores normalized URLs, so normalize here too: a link
              // written with a trailing slash still matches its configured server.
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
            conversation: value(conversationQueryItem)
        )
    }

    private static func trimmed(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// What the app should do with one bot deep link, decided before any navigation so
/// every outcome is testable without a view (#554).
enum BotDeepLinkOutcome: Equatable {
    /// Nothing to route: Bot Mode is off, the named server is gone, or its Bot
    /// connection was removed or replaced. The app opens normally, with no error.
    case ignore
    /// Hold the destination until the user is signed in, then resolve it again.
    case waitForSignIn(BotDestination)
    /// Make the destination's server active first. That rebuilds the logged-in tree
    /// against it, and the held destination routes there.
    case switchServer(ServerAccount, BotDestination)
    /// The destination's server is already active: hand it to the Bots inbox.
    case open(BotDestination)
}

/// Turns a bot deep link into an outcome, using only what the app already knows —
/// the Bot Mode gate, the server registry, the per-server Bot connection and the
/// auth state. The roster is not consulted here: an unknown Profile is resolved by
/// the inbox it lands on, so a link never waits on a socket to be routed.
@MainActor enum BotDeepLinkRouter {
    static func resolve(
        _ destination: BotDestination,
        state: AuthManager.State,
        servers: [ServerAccount],
        isBotModeEnabled: Bool,
        // Main-actor isolated so the default can read the per-server Keychain record
        // the way every other caller does.
        botConnectionID: @MainActor (URL) -> UUID? = { @MainActor url in
            (try? BotConnectionStore().load(server: url))?.id
        }
    ) -> BotDeepLinkOutcome {
        // Bot Mode off: the session list opens and no Bot UI leaks through a link.
        guard isBotModeEnabled else { return .ignore }
        guard let account = servers.first(where: { $0.id == destination.server.absoluteString }) else {
            return .ignore
        }
        // A replaced endpoint or account mints a new connection UUID, so this also
        // covers "the link names a bot on a connection this server no longer has".
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

    /// Whether an inbox in this state can answer a held link now. A live roster can.
    /// A connecting or quietly retrying socket cannot yet, and the link waits rather
    /// than being lost to a transient failure. An inbox that has settled with no Bot
    /// connection at all never will, so the link is dropped instead of held forever.
    static func inboxCanAnswer(link: BotInbox.Link, hasConnection: Bool, hasSettled: Bool) -> Bool {
        link == .live || (hasSettled && !hasConnection)
    }

    /// The bot a held destination names on the roster now on screen, or nil when the
    /// connection was replaced under it or the server no longer has that Profile.
    /// Equal Profile names on two connections never match each other.
    static func profile(
        for destination: BotDestination,
        connection: BotConnection?,
        profiles: [BotProfile]
    ) -> BotProfile? {
        guard let connection, connection.id == destination.connectionID else { return nil }
        return profiles.first { $0.id == destination.profile }
    }
}

/// The inbox's presented chat and optional linked root. Resolving a link replaces
/// the whole selection, including when its Profile is no longer on the roster.
struct BotInboxSelection {
    var profile: BotProfile?
    var room: BotRoomKey?
    var conversation: String?

    @MainActor mutating func open(
        _ destination: BotDestination, connection: BotConnection?, profiles: [BotProfile]
    ) {
        profile = BotDeepLinkRouter.profile(for: destination, connection: connection, profiles: profiles)
        room = nil
        conversation = profile == nil ? nil : destination.conversation
    }
}
