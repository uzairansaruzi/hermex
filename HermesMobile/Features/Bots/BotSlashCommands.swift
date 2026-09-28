import Foundation

/// The `/…` the caret sits in, when it can actually run something here.
///
/// Narrower than the Sessions trigger on purpose. A Bot host only expands a
/// skill from the start of a message, so a `/` mid-sentence offers nothing, and
/// the trigger ends at its first space: past that the user is writing the
/// skill's argument, not choosing a row.
struct BotSlashTrigger: Equatable {
    /// UTF-16 range of the trigger inside the draft: the `/` up to the caret.
    let range: NSRange
    /// What the panel filters on, without the leading `/`.
    let query: String

    static func detect(in draft: String, selection: NSRange) -> Self? {
        guard let trigger = ComposerSlashTrigger.detect(in: draft, selection: selection), trigger.startsDraft else {
            return nil
        }
        let query = trigger.text.dropFirst()
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return Self(range: trigger.range, query: String(query))
    }

    /// What the draft and caret become when the user accepts a row. Only the
    /// trigger's own range changes, so text after the caret survives.
    func applying(_ replacement: String, to draft: String) -> (draft: String, selection: NSRange) {
        ComposerSlashTrigger(range: range, text: "/" + query, startsDraft: true).applying(replacement, to: draft)
    }
}

/// The `/name rest` a draft opens with.
struct BotSlashInvocation: Equatable {
    let name: String
    let argument: String
}

/// What a Bot connection's `commands.catalog` offers the composer, and how a
/// typed invocation is read back out of a draft.
///
/// Skills only. The gateway never interprets a leading `/` in `prompt.submit`:
/// slash work lives in `slash.exec` and `command.dispatch`, and Bot Mode exposes
/// no general slash runner, so a command row would insert text nothing runs.
enum BotSlashCatalog {
    /// The skills in a `commands.catalog` reply, by name.
    ///
    /// The host answers in two halves: the `skills` keys say which entries are
    /// skills, and the `pairs` rows carry every entry's description. A key that
    /// also appears in `canon` or `commands` is dropped, because those are
    /// registry, quick or plugin commands, which `command.dispatch` resolves
    /// *ahead of* skills — and a `quick_commands` entry of type `exec` runs a
    /// shell command on the host. Names are never invented from `pairs` alone.
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
            // Identity and the composer's chips both key off the slug, so a name
            // without one, or a second name that slugs the same, cannot be drawn.
            let slug = SlashSkillFormatter.slug(for: name)
            guard !slug.isEmpty, seen.insert(slug).inserted else { continue }
            suggestions.append(SkillSlashSuggestion(
                name: name, category: trimmed(info["origin"].text), description: descriptions[key]))
        }

        return suggestions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The `/name rest` `draft` opens with, or `nil` when it opens with prose.
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
