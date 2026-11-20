import Foundation
import Network

struct BotConnection: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let address: URL
    let username: String
    var password: String
    var hermesVersion: String?
    var installID: String?
    var headers: [CustomHeader]?
    var oauth: HermesOAuth?

    var hasNoCredentials: Bool { username.isEmpty && oauth == nil }

    static func installID(in status: BotJSON) -> String? {
        guard let value = status["install_id"].text, !value.isEmpty else { return nil }
        return value
    }

    func requireSameInstall(_ live: String?) throws {
        if let installID, let live, installID != live { throw BotFailure.differentHost }
    }

    private static let dashboardPaths: Set<String> = ["login", "auth", "api", "chat", "sessions"]

    static func address(_ text: String) throws -> URL {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { throw BotAddressError.invalid }
        let hasScheme = value.contains("://")
        if !hasScheme {
            if IPv6Address(value) != nil { value = "[\(value)]" }
            value = "https://" + value
        }
        guard var parts = URLComponents(string: value) else { throw BotAddressError.invalid }
        switch parts.scheme?.lowercased() {
        case "ws": parts.scheme = "http"
        case "wss": parts.scheme = "https"
        default: break
        }
        parts.query = nil
        parts.fragment = nil
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        guard ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw BotAddressError.invalid }
        let plainHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !plainHost.allSatisfy({ $0.isNumber || $0 == "." }) || IPv4Address(plainHost) != nil else {
            throw BotAddressError.invalid
        }
        if let first = path.split(separator: "/").first, !dashboardPaths.contains(first.lowercased()) {
            throw BotAddressError.path(path)
        }
        if !hasScheme && defaultsToHTTP(plainHost.lowercased()) { parts.scheme = "http" }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        parts.path = ""
        guard let url = parts.url else { throw BotAddressError.invalid }
        return url
    }

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

struct HermesOAuth: Codable, Equatable {
    let provider: String
    let userID: String
    var refreshToken: String
}

enum BotAddressError: LocalizedError, Equatable {
    case path(String)
    case invalid

    var errorDescription: String? {
        switch self {
        case .path(let path):
            let shown = "\u{2068}\(path)\u{2069}"
            return String(localized: "Remove “\(shown)” from the address. Hermex needs the dashboard's main address, like https://example.com:9119, and can't use a dashboard served under a path yet.")
        case .invalid:
            return String(localized: "Enter the dashboard's HTTP or HTTPS address, like https://example.com:9119, without a username or password.")
        }
    }
}

@MainActor struct BotConnectionStore {
    var keychain: any KeychainStoring = KeychainStore()
    var limitsPublisher: ProviderLimitsPublisher = .shared
    func load(server: URL) throws -> BotConnection? {
        guard let value = try keychain.load(.botConnection, scope: server.absoluteString) else { return nil }
        return try JSONDecoder().decode(BotConnection.self, from: Data(value.utf8))
    }
    func save(_ connection: BotConnection, server: URL) throws {
        let value = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
        try keychain.save(value, forKey: .botConnection, scope: server.absoluteString)
        HermesConnections.shared.retire(server: server, unlessStill: connection)
        limitsPublisher.invalidate(server: server, unlessConnection: connection.id)
    }
    func saveRotatedRefreshToken(_ rotated: String, replacing sent: String, connection id: UUID, server: URL) throws {
        guard var saved = try load(server: server), saved.id == id, saved.oauth?.refreshToken == sent else { return }
        saved.oauth?.refreshToken = rotated
        let value = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        try keychain.save(value, forKey: .botConnection, scope: server.absoluteString)
    }
    func remove(server: URL) throws {
        try keychain.delete(.botConnection, scope: server.absoluteString)
        HermesConnections.shared.retire(server: server)
        limitsPublisher.invalidate(server: server)
    }
}

struct BotProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let title: String?
    let displayName: String?
    let description: String?
    let model: String?
    let preview: String?
    let lastActive: Date?
    let canonicalID: String?
    let canonicalTipID: String?
    let pinned: Bool
    let hidden: Bool
    let sectionID: String?
    let sectionName: String?
    let look: [String: BotJSON]
    let hasAvatar: Bool
    let lookRevision: Int?
    var isPhoto: Bool { look["imageKind"]?.text == "photo" }

    init?(_ row: BotJSON) {
        guard let profile = row["name"].text, !profile.isEmpty else { return nil }
        id = profile
        let look = row["ui_meta"]["hermes-bots"]
        title = Self.firstText(look["title"])
        displayName = Self.firstText(row["display_name"])
        name = Self.firstText(look["title"], row["display_name"]) ?? (profile == "default" ? "Hermes" : profile)
        description = Self.firstText(look["description"], row["description"])
        model = Self.firstText(row["model"])
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

enum BotLiveStatus: Int, Comparable {
    case working
    case waiting

    init?(wire: String?) {
        switch wire {
        case "waiting": self = .waiting
        case "working", "starting", "streaming": self = .working
        default: return nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

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
