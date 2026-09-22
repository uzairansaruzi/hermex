import Foundation
import Network

struct BotConnection: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let address: URL
    let username: String
    var password: String
    /// Release string `/api/status` reported at the last successful connect. Nil for
    /// records saved before the pin existed or when the host omits `version`.
    var hermesVersion: String?

    /// The hermes-agent release Hermex was validated against. Mirrors line 2 of
    /// `HERMES_AGENT_TESTED_SHA`; `BotConnectionVersionTests` fails when they drift.
    static let testedHermesVersion = "0.21.2"

    static func address(_ text: String) throws -> URL {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { throw BotFailure.invalidAddress }
        let hasScheme = value.contains("://")
        if !hasScheme {
            // A bare IPv6 literal needs brackets; bracketed literals may include a port.
            if IPv6Address(value) != nil { value = "[\(value)]" }
            value = "https://" + value
        }
        guard var parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw BotFailure.invalidAddress }
        let plainHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !plainHost.allSatisfy({ $0.isNumber || $0 == "." }) || IPv4Address(plainHost) != nil else {
            throw BotFailure.invalidAddress
        }
        if !hasScheme && defaultsToHTTP(plainHost.lowercased()) { parts.scheme = "http" }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        parts.path = ""
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return url
    }

    /// Infer a scheme only for an omitted one, never as a retry after TLS fails.
    private static func defaultsToHTTP(_ host: String) -> Bool {
        if let address = IPv4Address(host) { return privateIPv4(Array(address.rawValue)) }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            if bytes.prefix(12) == Array(repeating: UInt8(0), count: 10) + [255, 255] {
                return privateIPv4(Array(bytes.suffix(4)))
            }
            return bytes == Array(repeating: UInt8(0), count: 15) + [1]
                || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || (!host.contains(".") && !host.contains(":"))
    }

    private static func privateIPv4(_ octets: [UInt8]) -> Bool {
        octets[0] == 10 || octets[0] == 127
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 100 && (64...127).contains(octets[1]))
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

/// One `profiles.list` row. Identity comes only from server fields: the Desktop
/// title, then the core `display_name`, then the Profile name (`default` reads as
/// Hermes, as in Desktop). Description follows the same Desktop-then-core order.
/// Pinned and hidden are Desktop's roster organization; its user sections are
/// not here because their catalog lives in Desktop's local storage, so a bare
/// `sectionId` cannot be named, and `groups` are executable group rooms, not sections.
struct BotProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let title: String?
    let displayName: String?
    let description: String?
    let preview: String?
    let lastActive: Date?
    let pinned: Bool
    let hidden: Bool
    /// Desktop's `ui_meta["hermes-bots"]` object as received. A pin or hide write
    /// sends it back whole with one field changed, so Desktop-only fields survive.
    let look: [String: BotJSON]
    /// True when the host has an avatar asset, so the inbox fetches only rows that have one.
    let hasAvatar: Bool
    /// Desktop's compare-and-swap revision for this bot's look
    /// (`ui_meta_revisions["hermes-bots"]`). Nil when the host or bot has none; the
    /// avatar is then refetched on every roster load instead of served from memory.
    let lookRevision: Int?

    init?(_ row: BotJSON) {
        guard let profile = row["name"].text, !profile.isEmpty else { return nil }
        id = profile
        let look = row["ui_meta"]["hermes-bots"]
        title = Self.firstText(look["title"])
        displayName = Self.firstText(row["display_name"])
        name = Self.firstText(look["title"], row["display_name"]) ?? (profile == "default" ? "Hermes" : profile)
        description = Self.firstText(look["description"], row["description"])
        preview = row["canonical_session"]["preview"].text
        lastActive = row["canonical_session"]["last_active"].number.map(Date.init(timeIntervalSince1970:))
        pinned = look["pinned"].flag == true
        hidden = look["hidden"].flag == true
        self.look = look.fields ?? [:]
        hasAvatar = row["has_avatar"].flag == true
        lookRevision = row["ui_meta_revisions"]["hermes-bots"].integer
    }

    private static func firstText(_ candidates: BotJSON...) -> String? {
        for candidate in candidates {
            let trimmed = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
