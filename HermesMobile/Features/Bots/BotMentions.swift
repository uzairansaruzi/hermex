import UIKit

/// Identification only, using one connection's inbox roster. No delivery or relay
/// work belongs here; the annotated prompt follows the ordinary command path.
struct BotMentions {
    struct Completion: Identifiable {
        let profile: BotProfile
        let tag: String
        var id: String { profile.id }
    }

    private let candidates: [Completion]
    private let byForm: [String: BotProfile]
    private static let reserved: Set<String> = ["all", "everyone", "user", "default", "hermes"]
    private static let tokens = try! NSRegularExpression(pattern: #"(^|\s)@([a-z0-9][a-z0-9_-]*)"#, options: .caseInsensitive)
    private static let fences = try! NSRegularExpression(pattern: #"```[\s\S]*?```"#)
    private static let inlineCode = try! NSRegularExpression(pattern: #"`[^`\n]*`"#)
    private static let notePrefix = "\n\n[@mentions resolved from the Bot Mode roster — the user is referring to: "
    private static let noteSuffix = ". If they want one of these agents contacted, compose your own message and send it with your message_agent tool (agents on other connected machines are reachable too — the Desktop relays it); never forward the user’s text verbatim. If this session has no message_agent tool, agent messaging is unavailable here — say so.]"
    private static let noteLines = try! NSRegularExpression(
        pattern: #"\A@[a-zA-Z0-9][a-zA-Z0-9_-]* = agent profile "[^"\r\n]+"(?: \("[\s\S]*?"\))?(?:; @[a-zA-Z0-9][a-zA-Z0-9_-]* = agent profile "[^"\r\n]+"(?: \("[\s\S]*?"\))?)*\z"#
    )

    init(roster: [BotProfile], excluding active: String) {
        var candidates: [Completion] = []
        var byForm: [String: BotProfile] = [:]
        var ambiguous = Set<String>()
        var seen = Set<String>()
        for bot in roster where bot.id != active && seen.insert(bot.id).inserted {
            let friendlyForms = [bot.title, bot.displayName].flatMap { Self.nameForms($0) }
            candidates.append(Completion(profile: bot, tag: friendlyForms.first ?? Self.handle(bot)))
            for form in Set(friendlyForms + [Self.handle(bot).lowercased(), bot.id.lowercased()]) {
                if let previous = byForm[form], previous.id != bot.id { ambiguous.insert(form) }
                byForm[form] = bot
            }
        }
        for form in ambiguous { byForm.removeValue(forKey: form) }
        self.candidates = candidates.compactMap { candidate in
            let bot = candidate.profile
            let forms = [candidate.tag, Self.handle(bot), bot.id]
            guard let tag = forms.first(where: { byForm[$0.lowercased()]?.id == bot.id }) else { return nil }
            return Completion(profile: bot, tag: tag)
        }
        self.byForm = byForm
    }

    static func handle(_ bot: BotProfile) -> String {
        bot.id.lowercased() == "default" ? "hermes" : bot.id
    }

    /// Desktop's slug and collapsed forms; reserved words only block friendly
    /// aliases, so the primary Profile still owns @hermes and @default.
    static func nameForms(_ value: String?) -> [String] {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return [] }
        let slug = name.replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let collapsed = name.replacingOccurrences(of: "[^a-z0-9_-]+", with: "", options: .regularExpression)
        var seen = Set<String>()
        return [slug, collapsed].filter {
            $0.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
                && !reserved.contains($0) && seen.insert($0).inserted
        }
    }

    func completions(query: String) -> [Completion] {
        let query = query.lowercased()
        return Array(candidates.filter {
            query.isEmpty || [$0.tag, Self.handle($0.profile), $0.profile.name].contains { $0.lowercased().hasPrefix(query) }
        }.prefix(8))
    }

    /// Every unambiguous alias is available to the shared composer editor.
    func chipReferences(avatars: [String: UIImage]) -> [String: ComposerBotReference] {
        byForm.mapValues { ComposerBotReference(profile: $0, avatar: avatars[$0.id]) }
    }

    /// Preserve UTF-16 offsets while masking code, so sending and chip display
    /// resolve the same prose without shifting a chip onto unrelated text.
    static func proseMentions(in text: String) -> [(range: NSRange, form: String)] {
        let prose = NSMutableString(string: text)
        for regex in [fences, inlineCode] {
            for match in regex.matches(in: prose as String, range: NSRange(location: 0, length: prose.length)).reversed() {
                prose.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
        return tokens.matches(in: prose as String, range: NSRange(location: 0, length: prose.length)).map {
            let token = $0.range(at: 2)
            return (NSRange(location: token.location - 1, length: token.length + 1), prose.substring(with: token).lowercased())
        }
    }

    func resolve(_ text: String) -> [BotProfile] {
        var seen = Set<String>()
        return Self.proseMentions(in: text).compactMap {
            guard let bot = byForm[$0.form], seen.insert(bot.id).inserted else { return nil }
            return bot
        }
    }

    func annotation(for text: String) -> String {
        let bots = resolve(text)
        guard !bots.isEmpty else { return "" }
        let lines = bots.map { bot in
            "@\(Self.handle(bot)) = agent profile \"\(bot.id)\"" + (bot.title.map { " (\"\($0)\")" } ?? "")
        }.joined(separator: "; ")
        return Self.notePrefix + lines + Self.noteSuffix
    }

    /// Hide only a trailing identification note in user presentation. Drafts and
    /// transport text retain their original bytes, including whitespace.
    static func displayText(_ text: String) -> String {
        guard let start = text.range(of: notePrefix, options: .backwards),
              text.hasSuffix(noteSuffix) else { return text }
        let end = text.index(text.endIndex, offsetBy: -noteSuffix.count)
        guard start.upperBound <= end else { return text }
        let lines = String(text[start.upperBound..<end])
        let range = NSRange(lines.startIndex..., in: lines)
        guard noteLines.firstMatch(in: lines, range: range)?.range == range else { return text }
        return String(text[..<start.lowerBound])
    }
}

/// Caret-local @ token. Uses the slash completion's UTF-16 replacement behavior
/// so text on either side and the editor's selection ownership are preserved.
struct BotMentionTrigger {
    let range: NSRange
    let query: String
    private static let token = try! NSRegularExpression(pattern: #"(^|\s)@([a-z0-9_-]*)$"#, options: .caseInsensitive)

    static func detect(in text: String, selection: NSRange) -> Self? {
        let text = text as NSString
        guard selection.length == 0, selection.location >= 0, selection.location <= text.length else { return nil }
        let prefix = text.substring(to: selection.location)
        guard let match = token.firstMatch(in: prefix, range: NSRange(location: 0, length: selection.location)) else { return nil }
        let queryRange = match.range(at: 2)
        return Self(range: NSRange(location: queryRange.location - 1, length: queryRange.length + 1),
                    query: text.substring(with: queryRange))
    }

    func applying(tag: String, to text: String) -> (draft: String, selection: NSRange) {
        ComposerSlashTrigger(range: range, text: "@" + query, startsDraft: false).applying("@" + tag + " ", to: text)
    }
}
