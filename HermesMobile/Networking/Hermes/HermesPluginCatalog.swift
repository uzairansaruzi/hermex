import Foundation

/// One entry of the host's plugin catalog (#1582), decoded tolerantly. Catalog data comes only from
/// the host. `name` is what an install sends.
struct HermesCatalogEntry: Identifiable, Equatable, Sendable {
    /// An unknown tier reads as community, the one the review warns about most.
    enum Tier: Equatable, Sendable {
        case official, verified, community

        init(_ raw: String?) {
            switch raw {
            case "official": self = .official
            case "verified": self = .verified
            default: self = .community
            }
        }
    }

    let name: String
    let title: String
    let repo: String
    /// The full reviewed commit, which an install sends.
    let pin: String
    /// The short form the review shows.
    let commit: String
    let tier: Tier
    let category: String
    let maintainer: String
    let version: String
    /// The description before its `Disclosure:` marker.
    let summary: String
    /// The reviewer's disclosure, word for word.
    let disclosure: String?
    let requiresHermes: String
    let platforms: [String]
    let requiredKeys: [String]
    let knownIssues: [String]

    var id: String { name }
    var needsDesktop: Bool { category == "desktop" }

    init?(_ row: BotJSON) {
        guard let name = row["name"].text, !name.isEmpty else { return nil }
        self.name = name
        let title = row["title"].text ?? ""
        self.title = title.isEmpty ? name : title
        repo = row["repo"].text ?? ""
        pin = row["sha"].text ?? ""
        commit = row["sha_short"].text ?? String(pin.prefix(7))
        tier = Tier(row["tier"].text)
        category = row["category"].text ?? ""
        maintainer = row["maintainer"].text ?? ""
        version = row["version"].text ?? ""
        (summary, disclosure) = Self.split(row["description"].text ?? "")
        requiresHermes = row["requires_hermes"].text ?? ""
        platforms = (row["platforms"].list ?? []).compactMap(\.text)
        requiredKeys = (row["capabilities"]["requires_env"].list ?? []).compactMap(\.text)
        knownIssues = (row["known_issues"].list ?? []).compactMap(\.text)
    }

    /// The repository as `owner/name` when it's on GitHub, otherwise as the host gave it.
    var source: String {
        repo.replacingOccurrences(of: "https://github.com/", with: "")
    }

    /// Whether a host on `hostVersion` is too old for this entry. An unreadable version on either
    /// side isn't a reason to refuse: the host checks the manifest itself.
    func isTooNew(forHost hostVersion: String?) -> Bool {
        guard let host = HermesCompatibility.release(hostVersion), requiresHermes.hasPrefix(">=") else { return false }
        let needed = requiresHermes.dropFirst(2).split(separator: ".").map { Int($0) }
        guard !needed.isEmpty, !needed.contains(nil) else { return false }
        return host.lexicographicallyPrecedes(needed.compactMap { $0 } + Array(repeating: 0, count: max(0, 3 - needed.count)))
    }

    /// The minimum release as the review names it, without the host's `>=`.
    var minimumHermes: String { String(requiresHermes.drop { !$0.isNumber }) }

    /// Splits at the same `Disclosure:` or `Disclosure —` marker upstream reads.
    private static func split(_ description: String) -> (summary: String, disclosure: String?) {
        let text = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let marker = text.range(of: #"\bDisclosure\s*[:—]\s*"#, options: .regularExpression) else { return (text, nil) }
        let disclosure = String(text[marker.upperBound...])
        return (text[..<marker.lowerBound].trimmingCharacters(in: .whitespaces), disclosure.isEmpty ? nil : disclosure)
    }
}

/// The host's catalog, held in memory while the Plugins screen is open and never written to disk.
struct HermesPluginCatalog: Equatable, Sendable {
    let entries: [String: HermesCatalogEntry]
    /// Why Nous took a name out of the catalog, by name.
    let removalReasons: [String: String]

    /// A reply that isn't JSON is a failed read. Rows the catalog can't name are left out.
    init(_ body: Data) throws {
        let reply: BotJSON
        do { reply = try JSONDecoder().decode(BotJSON.self, from: body) } catch { throw APIError.decoding(underlying: error) }
        entries = Dictionary((reply["entries"].list ?? []).compactMap(HermesCatalogEntry.init).map { ($0.name, $0) },
                             uniquingKeysWith: { first, _ in first })
        removalReasons = Dictionary((reply["removed"].list ?? []).compactMap { row in
            row["name"].text.map { ($0, row["reason"].text ?? "") }
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// What the install field holds, which accepts everything a person might paste: a repository or URL,
/// a catalog name, `hermes plugins install <name>`, or a `hermes://plugin/install` link. Whatever a
/// link asks for, the review still decides, so its `force` and `enable` are ignored.
enum PluginInstallInput: Equatable, Sendable {
    case empty
    case catalogName(String)
    case repo(String)
    case invalid

    init(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { self = .empty; return }
        if text.hasPrefix("hermes://") {
            self = Self.link(text)
            return
        }
        let command = "hermes plugins install "
        if text.hasPrefix(command) {
            // Flags such as `--force` are left to the review.
            guard let target = text.dropFirst(command.count).split(whereSeparator: \.isWhitespace).first(where: { !$0.hasPrefix("-") })
            else { self = .invalid; return }
            text = String(target)
        }
        guard !text.contains(where: \.isWhitespace) else { self = .invalid; return }
        if text.contains("/") || text.contains(":") {
            self = .repo(text)
        } else {
            self = Self.isCatalogName(text) ? .catalogName(text) : .invalid
        }
    }

    private static func link(_ text: String) -> Self {
        guard let parts = URLComponents(string: text), parts.host == "plugin", parts.path == "/install" else { return .invalid }
        func value(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name = value("catalog"), isCatalogName(name) { return .catalogName(name) }
        if let repo = value("repo"), !repo.isEmpty, !repo.contains(where: \.isWhitespace) { return .repo(repo) }
        return .invalid
    }

    /// Upstream's bare `[a-z0-9_-]` token, so a link can't pass a repository off as a catalog name.
    private static func isCatalogName(_ text: String) -> Bool {
        text.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }
}
