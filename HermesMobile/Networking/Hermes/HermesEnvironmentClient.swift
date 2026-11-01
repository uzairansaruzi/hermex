import Foundation

/// One variable a Profile's `.env` can hold, as `GET /api/env` lists it (#1318): a key the host's
/// catalog knows, or a custom one the `.env` carries. `preview` is the host's mask, never the value.
struct HermesEnvKey: Identifiable, Hashable, Sendable {
    let name: String
    let category: Category
    /// The provider's label, or the variable name when the host has none.
    let title: String
    let description: String?
    let isSet: Bool
    /// The masked value, `sk-o…7890` or `•••` for a short one; nil when unset.
    let preview: String?
    /// Listed in the Add Key picker only while searching.
    let isAdvanced: Bool

    var id: String { name }
    /// Whether the title is a label, so the variable name shows under it.
    var hasLabel: Bool { title != name }

    /// The host's `category`, in the order the screens list them; any other is kept after them.
    enum Category: Hashable, Comparable, Sendable {
        case provider, tool, skill, setting, messaging, custom
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "provider": self = .provider
            case "tool": self = .tool
            case "skill": self = .skill
            case "setting": self = .setting
            case "messaging": self = .messaging
            case "custom": self = .custom
            default: self = .other(raw)
            }
        }

        var title: String {
            switch self {
            case .provider: String(localized: "Providers")
            case .tool: String(localized: "Tools")
            case .skill: String(localized: "Skills")
            case .setting: String(localized: "Settings")
            case .messaging: String(localized: "Messaging")
            case .custom: String(localized: "Custom")
            case .other(let raw): raw.isEmpty ? String(localized: "Other") : raw.capitalized
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.other(let left), .other(let right)): left < right
            default: lhs.rank < rhs.rank
            }
        }

        private var rank: Int {
            switch self {
            case .provider: 0
            case .tool: 1
            case .skill: 2
            case .setting: 3
            case .messaging: 4
            case .custom: 5
            case .other: 6
            }
        }
    }

    /// One category's keys, as the screens list them.
    struct Section: Identifiable {
        let category: Category
        let keys: [HermesEnvKey]
        var id: Category { category }
    }

    /// `keys` by category in display order, each sorted by title, then name.
    static func sections(_ keys: [HermesEnvKey]) -> [Section] {
        Dictionary(grouping: keys, by: \.category)
            .sorted { $0.key < $1.key }
            .map { category, keys in
                Section(category: category, keys: keys.sorted { lhs, rhs in
                    let order = lhs.title.localizedStandardCompare(rhs.title)
                    return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
                })
            }
    }

    /// The host's mask without its `«redacted:…»` wrapper, with `...` as `…` and a short value's
    /// `***` as `•••`. Anything else is shown as the host sent it.
    static func preview(_ redacted: String?) -> String? {
        guard var preview = redacted, !preview.isEmpty else { return nil }
        if preview.hasPrefix("«redacted:"), preview.hasSuffix("»") {
            preview = String(preview.dropFirst("«redacted:".count).dropLast())
        }
        return preview == "***" ? "•••" : preview.replacingOccurrences(of: "...", with: "…")
    }
}

/// The API Keys screen's client on a Hermes host (#1318): one Profile's `.env` under `/api/env`,
/// over the sign-in, headers and cookie jar the server's Bot screens share. Every request names
/// the Profile, and nothing is cached, so a key never shows under another server or Profile. A
/// value goes out once in a write's body and is never read back. A refusal the host explains,
/// such as an invalid name, reads as its `detail` (`HermesCronClient.accepted`).
@MainActor final class HermesEnvironmentClient {
    private let http: HermesConnection

    /// `server`'s saved connection, on the sign-in its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    /// The host's Profiles, over `profiles.list`, and the one to start on: the default, or the
    /// first listed when none is marked default.
    func profiles() async throws -> (names: [String], initial: String) {
        let profiles = try await HermesCronClient(http: http).cronProfiles()
        let names = profiles.compactMap(\.name)
        return (names, profiles.first { $0.isDefault == true }?.name ?? names.first ?? "default")
    }

    /// Every key the host knows for `profile`, set or not.
    func keys(profile: String) async throws -> [HermesEnvKey] {
        try Self.keys(try await send(.environment(profile: profile)))
    }

    func set(_ name: String, value: String, profile: String) async throws {
        _ = try await send(.setEnvironment(key: name, value: value, profile: profile))
    }

    func remove(_ name: String, profile: String) async throws {
        _ = try await send(.removeEnvironment(key: name, profile: profile))
    }

    /// `GET /api/env`'s object as keys, leaving out the messaging credentials the host's Channels
    /// page owns (`channel_managed`). A reply that is not an object is a failed read.
    static func keys(_ body: Data) throws -> [HermesEnvKey] {
        let rows: [String: BotJSON]
        do { rows = try JSONDecoder().decode([String: BotJSON].self, from: body) } catch {
            throw APIError.decoding(underlying: error)
        }
        return rows.compactMap { name, row in
            guard !name.isEmpty, row["channel_managed"].flag != true else { return nil }
            let label = row["provider_label"].text ?? ""
            let description = row["description"].text ?? ""
            return HermesEnvKey(name: name, category: .init(row["category"].text ?? ""),
                                  title: label.isEmpty ? name : label, description: description.isEmpty ? nil : description,
                                  isSet: row["is_set"].flag == true, preview: HermesEnvKey.preview(row["redacted_value"].text),
                                  isAdvanced: row["advanced"].flag == true)
        }
    }

    /// One request's body, or the failure `HermesCronClient.accepted` reads from its status. A
    /// dropped request reads as the webui's network failure, so a cancellation is recognised as one.
    private func send(_ rest: HermesREST) async throws -> Data {
        let reply: (body: Data, status: Int)
        do { reply = try await http.reply(rest) } catch let error as URLError { throw APIError.network(underlying: error) }
        return try HermesCronClient.accepted(reply)
    }
}
