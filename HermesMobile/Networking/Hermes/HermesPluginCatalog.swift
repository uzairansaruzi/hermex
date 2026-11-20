import Foundation

struct HermesCatalogEntry: Identifiable, Equatable, Sendable {
    enum Tier: Hashable, CaseIterable, Sendable {
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
    let pin: String
    let commit: String
    let tier: Tier
    let category: String
    let maintainer: String
    let version: String
    let summary: String
    let disclosure: String?
    let requiresHermes: String
    let image: URL?
    let screenshots: [URL]
    let searchText: String
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
        image = PluginCatalogImageRule.url(row["image"].text)
        screenshots = (row["screenshots"].list ?? []).compactMap { PluginCatalogImageRule.url($0.text) }
        searchText = [name, title, summary, maintainer, category].joined(separator: " ").lowercased()
    }

    var source: String {
        repo.replacingOccurrences(of: "https://github.com/", with: "")
    }

    func isTooNew(forHost hostVersion: String?) -> Bool {
        guard let host = HermesCompatibility.release(hostVersion), requiresHermes.hasPrefix(">=") else { return false }
        let needed = requiresHermes.dropFirst(2).split(separator: ".").map { Int($0) }
        guard !needed.isEmpty, !needed.contains(nil) else { return false }
        return host.lexicographicallyPrecedes(needed.compactMap { $0 } + Array(repeating: 0, count: max(0, 3 - needed.count)))
    }

    var minimumHermes: String { String(requiresHermes.drop { !$0.isNumber }) }

    private static func split(_ description: String) -> (summary: String, disclosure: String?) {
        let text = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let marker = text.range(of: #"\bDisclosure\s*[:—]\s*"#, options: .regularExpression) else { return (text, nil) }
        let disclosure = String(text[marker.upperBound...])
        return (text[..<marker.lowerBound].trimmingCharacters(in: .whitespaces), disclosure.isEmpty ? nil : disclosure)
    }
}

enum PluginCatalogImageRule {
    static func url(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              host == "github.com" || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com"),
              url.pathExtension.lowercased() != "svg"
        else { return nil }
        return url
    }
}

struct PluginDiscoverGroup: Identifiable, Equatable {
    let tier: HermesCatalogEntry.Tier
    let entries: [HermesCatalogEntry]
    var id: HermesCatalogEntry.Tier { tier }
}

struct HermesPluginCatalog: Equatable, Sendable {
    let entries: [String: HermesCatalogEntry]
    private let ordered: [HermesCatalogEntry]
    let removalReasons: [String: String]

    init(_ body: Data) throws {
        let reply: BotJSON
        do { reply = try JSONDecoder().decode(BotJSON.self, from: body) } catch { throw APIError.decoding(underlying: error) }
        let rows = (reply["entries"].list ?? []).compactMap(HermesCatalogEntry.init)
        entries = Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        ordered = HermesCatalogEntry.Tier.allCases.flatMap { tier in rows.filter { $0.tier == tier } }
        removalReasons = Dictionary((reply["removed"].list ?? []).compactMap { row in
            row["name"].text.map { ($0, row["reason"].text ?? "") }
        }, uniquingKeysWith: { first, _ in first })
    }

    var categories: [String] {
        let known = ["tools", "memory", "web", "models", "voice", "automation", "platform", "general", "desktop"]
        let present = Set(ordered.map(\.category)).subtracting([""])
        return known.filter(present.contains) + present.subtracting(known).sorted()
    }

    func groups(query: String, category: String?) -> [PluginDiscoverGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = ordered.filter { entry in
            if let category, entry.category != category { return false }
            if entry.needsDesktop, category == nil, query.isEmpty { return false }
            return query.isEmpty || entry.searchText.contains(query)
        }
        return HermesCatalogEntry.Tier.allCases.compactMap { tier in
            let entries = shown.filter { $0.tier == tier }
            return entries.isEmpty ? nil : PluginDiscoverGroup(tier: tier, entries: entries)
        }
    }
}

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

    private static func isCatalogName(_ text: String) -> Bool {
        text.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }
}
