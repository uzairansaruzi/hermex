import Foundation

struct BotSlashInvocation: Equatable {
    let name: String
    let argument: String
}

enum BotSlashCatalog {
    static func skills(from reply: BotJSON) -> [SkillSlashSuggestion] {
        guard let entries = reply["skills"].fields, !entries.isEmpty else { return [] }

        var shadowed = Set<String>()
        for (alias, canonical) in reply["canon"].fields ?? [:] {
            shadowed.insert(alias.lowercased())
            if let canonical = canonical.text { shadowed.insert(canonical.lowercased()) }
        }
        for key in (reply["commands"].fields ?? [:]).keys { shadowed.insert(key.lowercased()) }

        var descriptions: [String: String] = [:]
        for row in reply["pairs"].list ?? [] {
            guard let cells = row.list, let key = cells.first?.text,
                  let description = trimmed(cells.dropFirst().first?.text) else { continue }
            descriptions[key] = description
        }

        var seen = Set<String>()
        var suggestions: [SkillSlashSuggestion] = []
        for (key, info) in entries {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix("/") else { continue }
            let name = String(key.dropFirst())
            guard !name.isEmpty, name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !shadowed.contains(key.lowercased()), !shadowed.contains(name.lowercased())
            else { continue }
            let slug = SlashSkillFormatter.slug(for: name)
            guard !slug.isEmpty, seen.insert(slug).inserted else { continue }
            suggestions.append(SkillSlashSuggestion(
                name: name, category: trimmed(info["origin"].text), description: descriptions[key]))
        }

        return suggestions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func invocation(in draft: String) -> BotSlashInvocation? {
        let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.hasPrefix("/") else { return nil }
        let body = draft.dropFirst()
        guard let space = body.firstIndex(where: \.isWhitespace) else {
            return body.isEmpty ? nil : BotSlashInvocation(name: String(body), argument: "")
        }
        let name = String(body[body.startIndex..<space])
        guard !name.isEmpty else { return nil }
        return BotSlashInvocation(
            name: name,
            argument: String(body[space...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
