import Foundation

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
    static let testedHermesVersion = "0.21.1"

    /// One-line note for a host running a release other than the tested one. Nil when
    /// the version matches or was never reported: the contract is validated just in
    /// time by each RPC, so a mismatch informs the user and never blocks login.
    var untestedVersionNote: String? {
        guard let hermesVersion, hermesVersion != Self.testedHermesVersion else { return nil }
        return String(localized: "Untested Hermes version \(hermesVersion). Hermex was tested with \(Self.testedHermesVersion); some features may not work.")
    }

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

/// One `profiles.list` row. Identity comes only from server fields: the Desktop
/// title, then the core `display_name`, then the Profile name (`default` reads as
/// Hermes, as in Desktop). Description follows the same Desktop-then-core order.
/// Pinned and hidden are Desktop's roster organization; its user sections are
/// not here because their catalog lives in Desktop's local storage, so a bare
/// `sectionId` cannot be named, and `groups` are executable group rooms, not sections.
struct BotProfile: Identifiable, Hashable {
    let id: String
    let name: String
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
