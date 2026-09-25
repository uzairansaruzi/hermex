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
    static let testedHermesVersion = "0.21.4"

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
/// Pinned, hidden and the user section are Desktop's roster organization. Desktop
/// stamps each filed bot with the section's id and name (`sectionId`,
/// `sectionName`); its section list and order stay in Desktop's plugin storage.
/// `groups` are executable group rooms, not sections.
struct BotProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let title: String?
    let displayName: String?
    let description: String?
    let preview: String?
    let lastActive: Date?
    /// The canonical chat's root (`canonical_session.id`) and the compression tip
    /// the roster read resolved (`resolved_id`). `BotLiveStatus` matches runtimes
    /// against both; nil when the bot has no canonical chat.
    let canonicalID: String?
    let canonicalTipID: String?
    let pinned: Bool
    let hidden: Bool
    /// Desktop's user section, trimmed; nil when unfiled. A bot with an id but no
    /// name cannot be headed, so the inbox treats it as unfiled.
    let sectionID: String?
    let sectionName: String?
    /// Desktop's `ui_meta["hermes-bots"]` object as received. A pin, hide or section
    /// write sends it back whole with the changed fields applied, so Desktop-only
    /// fields survive.
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
        canonicalID = Self.firstText(row["canonical_session"]["id"])
        canonicalTipID = Self.firstText(row["canonical_session"]["resolved_id"])
        pinned = look["pinned"].flag == true
        hidden = look["hidden"].flag == true
        sectionID = Self.firstText(look["sectionId"])
        sectionName = Self.firstText(look["sectionName"])
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

/// A bot's live turn state from `session.active_list`, the host's list of live
/// runtimes in its own process. Only what the inbox shows: idle, a reaped
/// runtime, and any status this build does not know read as no status at all.
enum BotLiveStatus: Int, Comparable {
    /// A turn is running (`working`, `starting`, `streaming`).
    case working
    /// The runtime has an open approval, question or other request for the user.
    case waiting

    init?(wire: String?) {
        switch wire {
        case "waiting": self = .waiting
        case "working", "starting", "streaming": self = .working
        default: return nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Maps `session.active_list` items onto bots by `session_key`, which is the live
    /// compression tip or, before the agent exists, the stored key; so it is matched
    /// against both the canonical root and the tip the roster read. Items carry no
    /// Profile, and stored ids can repeat across Profiles, so a key that names more
    /// than one bot marks none of them. Several items on one bot: the most urgent wins.
    static func statuses(_ items: [BotJSON], profiles: [BotProfile]) -> [String: BotLiveStatus] {
        var owners: [String: Set<String>] = [:]
        for profile in profiles {
            for key in Set([profile.canonicalID, profile.canonicalTipID].compactMap { $0 }) {
                owners[key, default: []].insert(profile.id)
            }
        }
        var result: [String: BotLiveStatus] = [:]
        for item in items {
            guard let status = BotLiveStatus(wire: item["status"].text), let key = item["session_key"].text,
                  let matched = owners[key], matched.count == 1, let profile = matched.first else { continue }
            result[profile] = max(result[profile] ?? status, status)
        }
        return result
    }
}
