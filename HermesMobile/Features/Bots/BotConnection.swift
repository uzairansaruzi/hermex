import Foundation

struct BotConnection: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let address: URL
    let username: String
    var password: String

    static func address(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw BotFailure.invalidAddress }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        parts.path = ""
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return url
    }
}

/// One credential record per configured webui server. Replacing an endpoint or
/// account mints a new identity even when Profile names happen to match.
@MainActor struct BotConnectionStore {
    var keychain: any KeychainStoring = KeychainStore()
    func load(server: URL) throws -> BotConnection? {
        guard let value = try keychain.load(.botConnection, scope: server.absoluteString) else { return nil }
        return try JSONDecoder().decode(BotConnection.self, from: Data(value.utf8))
    }
    func save(_ connection: BotConnection, server: URL) throws {
        let value = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
        try keychain.save(value, forKey: .botConnection, scope: server.absoluteString)
    }
    func remove(server: URL) throws {
        try keychain.delete(.botConnection, scope: server.absoluteString)
    }
}

struct BotProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let preview: String?
    let lastActive: Date?

    init?(_ row: BotJSON) {
        guard let profile = row["name"].text, !profile.isEmpty else { return nil }
        id = profile
        let displayName = row["display_name"].text ?? ""
        name = displayName.isEmpty ? profile : displayName
        preview = row["canonical_session"]["preview"].text
        lastActive = row["canonical_session"]["last_active"].number.map(Date.init(timeIntervalSince1970:))
    }
}
