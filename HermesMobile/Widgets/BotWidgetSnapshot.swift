import Foundation

struct BotWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let widgetKind = "BotChat"
    static let maxServers = 16
    static let maxBotsPerServer = 200

    var version = currentVersion
    var servers: [Server] = []

    struct Server: Codable, Equatable, Sendable {
        let serverKey: String
        let title: String
        let bots: [Bot]
    }

    struct Bot: Codable, Equatable, Sendable {
        let profile: String
        let title: String
        let avatar: String
    }

    func bot(serverKey: String, profile: String) -> Bot? {
        servers.first { $0.serverKey == serverKey }?.bots.first { $0.profile == profile }
    }
}

struct BotWidgetSnapshotFile {
    static let maxBytes = 1024 * 1024

    let url: URL
    let avatarDirectory: URL

    init(directory: URL) {
        let widgets = directory.appendingPathComponent("Widgets", isDirectory: true)
        url = widgets.appendingPathComponent("bot-chats.json")
        avatarDirectory = widgets.appendingPathComponent("BotAvatars", isDirectory: true)
    }

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

    func write(_ snapshot: BotWidgetSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func avatarURL(_ avatar: String, dark: Bool) -> URL {
        avatarDirectory.appendingPathComponent("\(avatar)-\(dark ? "dark" : "light").png")
    }
}

struct BotWidgetDestination: Hashable, Sendable {
    static let host = "bot-widget"

    let serverKey: String
    let profile: String

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
