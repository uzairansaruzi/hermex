import Foundation

/// The `/…` run the caret is sitting in, if there is one.
///
/// The composer used to treat a draft as a slash query only when the whole draft
/// started with `/`, so `/` halfway through a sentence did nothing and accepting
/// a row threw the rest of the draft away. This finds the trigger at the caret
/// and reports the range it occupies, so accepting a row replaces only that much.
struct ComposerSlashTrigger: Equatable {
    /// UTF-16 range of the trigger inside the draft: the `/` up to the caret.
    let range: NSRange
    /// The trigger's text, `/` included. This is what the panel filters on.
    let text: String

    private static let slash: UInt16 = 0x2F

    /// The trigger `selection` sits in, or `nil` when there is none.
    ///
    /// A trigger is a `/` that starts the draft or follows whitespace, running
    /// forward to the caret and never across a line break. A selection with a
    /// length is never a trigger: the user is selecting text, not typing a
    /// command.
    static func detect(in draft: String, selection: NSRange) -> ComposerSlashTrigger? {
        guard selection.length == 0 else { return nil }

        let draft = draft as NSString
        let caret = selection.location
        guard caret >= 0, caret <= draft.length else { return nil }

        // Every `/` on the caret's line that could open a trigger, then the
        // outermost one that holds up. A path argument such as
        // `/workspace /Users/me/app` belongs to the command in front of it, so
        // the inner slash must never win.
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
            if isTrigger(text) {
                return ComposerSlashTrigger(range: range, text: text)
            }
        }

        return nil
    }

    /// What the draft and caret become when the user accepts `replacement`.
    ///
    /// Only the trigger's own range changes. When the completion wants a
    /// trailing space and the draft already has one waiting there, the space is
    /// dropped and the caret steps over the existing one instead, so accepting a
    /// command mid-sentence leaves neither a double space nor a caret stranded in
    /// front of one. A line break is not a separator, so it keeps the space.
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

    /// Whether `text` can still be a command being typed.
    ///
    /// One word is always a candidate. Past the first space, the word has to be
    /// a command that takes a sub-argument. Where that argument is one of a
    /// fixed list the trigger ends as soon as the user types past it, so prose
    /// such as "check the /tmp folder" or "use /reasoning high for this task"
    /// does not hold an empty panel open for the rest of the sentence. Where it
    /// is free-form — a workspace path, a personality name, a skill query — the
    /// spaces are part of the value, so the trigger runs to the caret.
    private static func isTrigger(_ text: String) -> Bool {
        let body = text.dropFirst()
        guard let space = body.firstIndex(where: { $0.isWhitespace }) else { return true }
        guard let command = SlashCommandCatalog.command(named: String(body[body.startIndex..<space])),
              command.subArgs != .none
        else {
            return false
        }
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
