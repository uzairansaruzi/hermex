import Foundation

struct ComposerSlashTrigger: Equatable {
    let range: NSRange
    let text: String
    let startsDraft: Bool

    private static let slash: UInt16 = 0x2F

    static func detect(in draft: String, selection: NSRange, scope: SlashCommandScope = .webui) -> ComposerSlashTrigger? {
        guard selection.length == 0 else { return nil }

        let draft = draft as NSString
        let caret = selection.location
        guard caret >= 0, caret <= draft.length else { return nil }

        var starts: [Int] = []
        var index = caret - 1
        while index >= 0 {
            let unit = draft.character(at: index)
            if isNewline(unit) { break }

            if unit == slash, index == 0 || isWhitespaceOrNewline(draft.character(at: index - 1)) {
                starts.append(index)
            }

            index -= 1
        }

        for start in starts.reversed() {
            let range = NSRange(location: start, length: caret - start)
            let text = draft.substring(with: range)
            let atDraftStart = isAtDraftStart(draft, before: start)
            if isTrigger(text, atDraftStart: atDraftStart, scope: scope) {
                return ComposerSlashTrigger(range: range, text: text, startsDraft: atDraftStart)
            }
        }

        return nil
    }

    func panelQuery(
        scope: SlashCommandScope,
        skills: [SkillSlashSuggestion],
        hasLoadedSkills: Bool,
        hostCompletion: HermesSlashCompletion?
    ) -> String? {
        let parsed = ParsedSlashQuery(query: text, scope: scope)
        if scope.isHermes, startsDraft, parsed.isHostArgumentMode,
           hostCompletion.map({ $0.items.isEmpty || !$0.applies(to: text) }) ?? true { return nil }
        if parsed.command?.subArgs == .skills,
           SlashSkillFormatter.invocation(from: parsed.argQuery, suggestions: skills) != nil {
            return nil
        }

        if parsed.command?.subArgs == .goalActions,
           parsed.isSubArgMode,
           !parsed.argQuery.isEmpty,
           !SlashCommandCatalog.goalActions.contains(where: {
               $0.hasPrefix(parsed.argQuery.lowercased())
           }) {
            return nil
        }

        if !startsDraft,
           hasLoadedSkills,
           SlashSkillFormatter.matching(parsed.commandName, in: skills).isEmpty {
            return nil
        }

        return text
    }

    func applying(_ replacement: String, to draft: String) -> (draft: String, selection: NSRange) {
        let draft = draft as NSString
        let location = min(max(0, range.location), draft.length)
        let range = NSRange(location: location, length: min(max(0, range.length), draft.length - location))

        var inserted = replacement
        var caretOffset = 0
        if inserted.hasSuffix(" "),
           range.upperBound < draft.length,
           Self.isSpace(draft.character(at: range.upperBound)) {
            inserted.removeLast()
            caretOffset = 1
        }

        let caret = range.location + (inserted as NSString).length + caretOffset
        return (
            draft.replacingCharacters(in: range, with: inserted),
            NSRange(location: caret, length: 0)
        )
    }

    private static func isAtDraftStart(_ draft: NSString, before start: Int) -> Bool {
        var index = start - 1
        while index >= 0 {
            guard isWhitespaceOrNewline(draft.character(at: index)) else { return false }
            index -= 1
        }
        return true
    }

    private static func isTrigger(_ text: String, atDraftStart: Bool, scope: SlashCommandScope) -> Bool {
        let body = text.dropFirst()
        guard let space = body.firstIndex(where: { $0.isWhitespace }) else { return true }
        guard atDraftStart else { return false }
        let name = String(body[body.startIndex..<space])
        guard let command = scope.command(named: name) else { return scope.completesOnHost(name) }
        guard command.subArgs != .none else { return false }
        guard !command.subArgs.allowsSpaces else { return true }

        let argument = body[body.index(after: space)...].drop(while: { $0.isWhitespace })
        return !argument.contains(where: { $0.isWhitespace })
    }

    private static func isWhitespaceOrNewline(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    private static func isNewline(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }
}
