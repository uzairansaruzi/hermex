import Foundation

/// The provider limits the Usage screen last loaded on a Hermes server (#1409), as the Limits
/// widget draws them. The app writes it (`ProviderLimitsPublisher`), the widget only reads it, so
/// the widget makes no network or Keychain call. It holds no server URL, credential or session:
/// the server is a SHA-256 digest of its configured URL, and the Profile and the Bot connection's
/// UUID name the scope a tap opens (`HermesUsageDestination`). Shared by the app and the widget.
struct ProviderLimitsSnapshot: Codable, Equatable, Sendable {
    /// The format this build reads and writes; any other version reads as no snapshot.
    static let currentVersion = 1
    /// The widget's kind, which a changed snapshot reloads.
    static let widgetKind = "ProviderLimits"
    /// How long a measurement's percentage shows: one hour, unless its window resets sooner.
    static let measurementLifetime: TimeInterval = 60 * 60
    static let maxProviders = 6
    static let maxWindows = 4

    var version = currentVersion
    /// `BotHistoryCache.Scope.key` of the server's configured URL.
    let serverKey: String
    let connectionID: UUID
    let profile: String
    /// When the app wrote it. Never makes a measurement fresh again: each window expires from its
    /// provider's own `updatedAt`.
    let publishedAt: Date
    let providers: [Provider]

    /// One provider card's percentage windows, with the time the host measured them.
    struct Provider: Codable, Equatable, Sendable {
        let id: String
        let title: String
        /// The host's measurement time, kept from the card even when a later refresh failed.
        /// Nil shows no percentage at all.
        let updatedAt: Date?
        /// The latest Usage refresh failed, so these are the last values loaded (#1408).
        let isStale: Bool
        let windows: [Window]
    }

    struct Window: Codable, Equatable, Sendable {
        let label: String
        /// 0–100, as the host reported it.
        let remainingPercent: Double
        let resetAt: Date?
    }

    /// The snapshot with the same content and another publication time, for skipping a write that
    /// would change nothing else.
    func published(at date: Date) -> Self {
        Self(version: version, serverKey: serverKey, connectionID: connectionID, profile: profile, publishedAt: date,
             providers: providers)
    }

    /// The instants after `now` at which some window stops showing its percentage, in order, for
    /// the widget's timeline entries.
    func deadlines(after now: Date) -> [Date] {
        let all = providers.flatMap { provider in provider.windows.map(provider.validUntil) }
        return Set(all.filter { $0 > now }).sorted()
    }
}

extension ProviderLimitsSnapshot.Provider {
    /// When `window`'s percentage stops showing: an hour after the measurement, or at the
    /// window's reset if sooner, after which the widget can't know the new allowance. A provider
    /// with no measurement time never shows one.
    func validUntil(_ window: ProviderLimitsSnapshot.Window) -> Date {
        guard let updatedAt else { return .distantPast }
        let expiry = updatedAt.addingTimeInterval(ProviderLimitsSnapshot.measurementLifetime)
        guard let resetAt = window.resetAt else { return expiry }
        return min(expiry, resetAt)
    }

    /// `window`'s remaining percentage while it is still valid at `now`, else nil.
    func remainingPercent(of window: ProviderLimitsSnapshot.Window, at now: Date) -> Double? {
        now < validUntil(window) ? window.remainingPercent : nil
    }
}

/// `<app group>/Widgets/provider-limits.json`, where the app leaves the snapshot for the widget.
/// A missing, oversized, unreadable or other-version file reads as no snapshot.
struct ProviderLimitsSnapshotFile {
    static let maxBytes = 64 * 1024

    let url: URL

    /// The file under `directory`, the app group's container in the app and the widget.
    init(directory: URL) {
        url = directory.appendingPathComponent("Widgets", isDirectory: true)
            .appendingPathComponent("provider-limits.json")
    }

    /// The app group's file, or nil when the build has no app group.
    static var shared: ProviderLimitsSnapshotFile? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return ProviderLimitsSnapshotFile(directory: container)
    }

    func read() -> ProviderLimitsSnapshot? {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxBytes,
              let snapshot = try? Self.decoder.decode(ProviderLimitsSnapshot.self, from: data),
              snapshot.version == ProviderLimitsSnapshot.currentVersion,
              snapshot.providers.count <= ProviderLimitsSnapshot.maxProviders,
              snapshot.providers.allSatisfy({ $0.windows.count <= ProviderLimitsSnapshot.maxWindows })
        else { return nil }
        return snapshot
    }

    /// Replaces the file atomically, readable by the widget once the phone was first unlocked.
    func write(_ snapshot: ProviderLimitsSnapshot) throws {
        let data = try Self.encoder.encode(snapshot)
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Deletes the file; true when there was one.
    @discardableResult
    func remove() -> Bool {
        (try? FileManager.default.removeItem(at: url)) != nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// The Usage screen a Limits widget tap opens (#1409): the Profile its snapshot was loaded in, on
/// the server and Bot connection it was loaded through. The server is the snapshot's digest, so
/// the link carries no URL; the app opens Usage only while that server is the signed-in active one
/// on the same connection, and never switches servers for it.
struct HermesUsageDestination: Hashable, Sendable {
    let serverKey: String
    let connectionID: UUID
    let profile: String

    /// `hermes-agent://usage?server=<digest>&connection=<UUID>&profile=<name>`.
    var url: URL? {
        var components = URLComponents()
        components.scheme = HermesDeepLink.scheme
        components.host = HermesDeepLink.usageHost
        components.queryItems = [
            URLQueryItem(name: HermesDeepLink.serverQueryItem, value: serverKey),
            URLQueryItem(name: "connection", value: connectionID.uuidString),
            URLQueryItem(name: HermesDeepLink.profileQueryItem, value: profile)
        ]
        return components.url
    }

    init(serverKey: String, connectionID: UUID, profile: String) {
        self.serverKey = serverKey
        self.connectionID = connectionID
        self.profile = profile
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == HermesDeepLink.scheme, url.host?.lowercased() == HermesDeepLink.usageHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == HermesDeepLink.serverQueryItem })?.value, !key.isEmpty,
              let connection = items.first(where: { $0.name == "connection" })?.value.flatMap(UUID.init(uuidString:)),
              let profile = items.first(where: { $0.name == HermesDeepLink.profileQueryItem })?.value
        else { return nil }
        self.init(serverKey: key, connectionID: connection, profile: profile)
    }
}

extension ProviderLimitsSnapshot {
    /// The Usage screen this snapshot came from.
    var destination: HermesUsageDestination {
        HermesUsageDestination(serverKey: serverKey, connectionID: connectionID, profile: profile)
    }
}
