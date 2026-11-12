import Foundation

/// The bots the Bot widget can show (#1643): every configured server's roster as its Bots inbox last
/// read it. The app writes it (`BotWidgetPublisher`), and the widget and its bot picker only read
/// it, so neither makes a network or Keychain call. It holds no server URL, host, connection UUID,
/// credential or session: a server is a SHA-256 digest of its configured URL
/// (`BotHistoryCache.Scope.key`), a bot its Profile name. Shared by the app and the widget.
struct BotWidgetSnapshot: Codable, Equatable, Sendable {
    /// The format this build reads and writes; any other version reads as no snapshot.
    static let currentVersion = 1
    /// The widget's kind, which a changed snapshot reloads.
    static let widgetKind = "BotChat"
    static let maxServers = 16
    static let maxBotsPerServer = 200

    var version = currentVersion
    var servers: [Server] = []

    struct Server: Codable, Equatable, Sendable {
        let serverKey: String
        /// The server's display name, or a neutral title when it has none of its own.
        let title: String
        let bots: [Bot]
    }

    struct Bot: Codable, Equatable, Sendable {
        let profile: String
        /// The title the Bots inbox shows.
        let title: String
        /// The avatar's base name under `BotWidgetSnapshotFile.avatarDirectory`, without its
        /// appearance suffix; the file may not be rendered yet.
        let avatar: String
    }

    /// The bot a widget entity names, or nil when its server or Profile is gone.
    func bot(serverKey: String, profile: String) -> Bot? {
        servers.first { $0.serverKey == serverKey }?.bots.first { $0.profile == profile }
    }
}

/// `<app group>/Widgets/bot-chats.json` and the avatars beside it, where the app leaves the Bot
/// widget's data. A missing, oversized, unreadable or other-version file reads as empty.
struct BotWidgetSnapshotFile {
    /// Room for every server at its row cap: 16 x 200 bots at about 300 bytes each.
    static let maxBytes = 1024 * 1024

    let url: URL
    let avatarDirectory: URL

    /// The files under `directory`, the app group's container in the app and the widget.
    init(directory: URL) {
        let widgets = directory.appendingPathComponent("Widgets", isDirectory: true)
        url = widgets.appendingPathComponent("bot-chats.json")
        avatarDirectory = widgets.appendingPathComponent("BotAvatars", isDirectory: true)
    }

    /// The app group's files, or nil when the build has no app group.
    static var shared: BotWidgetSnapshotFile? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return BotWidgetSnapshotFile(directory: container)
    }

    func read() -> BotWidgetSnapshot {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxBytes,
              let snapshot = try? JSONDecoder().decode(BotWidgetSnapshot.self, from: data),
              snapshot.version == BotWidgetSnapshot.currentVersion,
              snapshot.servers.count <= BotWidgetSnapshot.maxServers,
              snapshot.servers.allSatisfy({ $0.bots.count <= BotWidgetSnapshot.maxBotsPerServer })
        else { return BotWidgetSnapshot() }
        return snapshot
    }

    /// Replaces the file atomically, readable by the widget once the phone was first unlocked.
    func write(_ snapshot: BotWidgetSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A bot avatar's file for one appearance: the app renders a light and a dark copy, since a
    /// drawn face's default color is black on light and white on dark.
    func avatarURL(_ avatar: String, dark: Bool) -> URL {
        avatarDirectory.appendingPathComponent("\(avatar)-\(dark ? "dark" : "light").png")
    }
}

/// The chat a Bot widget's tap opens (#1643): a Profile on the server whose URL digest is
/// `serverKey`. It carries no URL or connection, so it outlives a sign-out; the app finds the
/// server by digest and the bot through that server's current Bot connection.
struct BotWidgetDestination: Hashable, Sendable {
    /// A host of its own, so `HermesDeepLink.botDestination(from:)` never reads it as a bot link.
    static let host = "bot-widget"

    let serverKey: String
    let profile: String

    /// `hermes-agent://bot-widget?server=<digest>&profile=<name>`.
    var url: URL? {
        var components = URLComponents()
        components.scheme = HermesDeepLink.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: HermesDeepLink.serverQueryItem, value: serverKey),
            URLQueryItem(name: HermesDeepLink.profileQueryItem, value: profile)
        ]
        return components.url
    }

    init(serverKey: String, profile: String) {
        self.serverKey = serverKey
        self.profile = profile
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == HermesDeepLink.scheme, url.host?.lowercased() == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == HermesDeepLink.serverQueryItem })?.value, !key.isEmpty,
              let profile = items.first(where: { $0.name == HermesDeepLink.profileQueryItem })?.value, !profile.isEmpty
        else { return nil }
        self.init(serverKey: key, profile: profile)
    }
}
