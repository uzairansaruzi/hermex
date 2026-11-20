import Foundation

struct ProviderLimitsSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let widgetKind = "ProviderLimits"
    static let measurementLifetime: TimeInterval = 60 * 60
    static let maxProviders = 6
    static let maxWindows = 4

    var version = currentVersion
    let serverKey: String
    let connectionID: UUID
    let profile: String
    let publishedAt: Date
    let providers: [Provider]

    struct Provider: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let updatedAt: Date?
        let isStale: Bool
        let windows: [Window]
    }

    struct Window: Codable, Equatable, Sendable {
        let label: String
        let remainingPercent: Double
        let resetAt: Date?
    }

    func published(at date: Date) -> Self {
        Self(version: version, serverKey: serverKey, connectionID: connectionID, profile: profile, publishedAt: date,
             providers: providers)
    }

    func deadlines(after now: Date) -> [Date] {
        let all = providers.flatMap { provider in provider.windows.map(provider.validUntil) }
        return Set(all.filter { $0 > now }).sorted()
    }
}

extension ProviderLimitsSnapshot.Provider {
    func validUntil(_ window: ProviderLimitsSnapshot.Window) -> Date {
        guard let updatedAt else { return .distantPast }
        let expiry = updatedAt.addingTimeInterval(ProviderLimitsSnapshot.measurementLifetime)
        guard let resetAt = window.resetAt else { return expiry }
        return min(expiry, resetAt)
    }

    func remainingPercent(of window: ProviderLimitsSnapshot.Window, at now: Date) -> Double? {
        now < validUntil(window) ? window.remainingPercent : nil
    }
}

struct ProviderLimitsSnapshotFile {
    static let maxBytes = 64 * 1024

    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("Widgets", isDirectory: true)
            .appendingPathComponent("provider-limits.json")
    }

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

    func write(_ snapshot: ProviderLimitsSnapshot) throws {
        let data = try Self.encoder.encode(snapshot)
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

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

struct HermesUsageDestination: Hashable, Sendable {
    let serverKey: String
    let connectionID: UUID
    let profile: String

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
    var destination: HermesUsageDestination {
        HermesUsageDestination(serverKey: serverKey, connectionID: connectionID, profile: profile)
    }
}
