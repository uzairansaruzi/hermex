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

        var index = caret - 1
        while index >= 0 {
            let unit = draft.character(at: index)
            if isNewline(unit) { return nil }

            if unit == slash, index == 0 || isWhitespaceOrNewline(draft.character(at: index - 1)) {
                let range = NSRange(location: index, length: caret - index)
                let text = draft.substring(with: range)
                if isTrigger(text) {
                    return ComposerSlashTrigger(range: range, text: text)
                }
            }

            index -= 1
        }

        return nil
    }

    /// What the draft and caret become when the user accepts `replacement`.
    ///
    /// Only the trigger's own range changes. When the completion wants a
    /// trailing space and the draft already has whitespace waiting there, the
    /// space is dropped and the caret steps over the existing one instead, so
    /// accepting a command mid-sentence leaves neither a double space nor a
    /// caret stranded in front of one.
    func applying(_ replacement: String, to draft: String) -> (draft: String, selection: NSRange) {
        let draft = draft as NSString
        let location = min(max(0, range.location), draft.length)
        let range = NSRange(location: location, length: min(max(0, range.length), draft.length - location))

        var inserted = replacement
        var caretOffset = 0
        if inserted.hasSuffix(" "),
           range.upperBound < draft.length,
           Self.isWhitespaceOrNewline(draft.character(at: range.upperBound)) {
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
    /// Everything up to the first space has to be a command that takes a
    /// sub-argument, otherwise ordinary prose such as "check the /tmp folder for
    /// it" would hold the panel open for the rest of the sentence.
    private static func isTrigger(_ text: String) -> Bool {
        let body = text.dropFirst()
        guard let space = body.firstIndex(where: { $0.isWhitespace }) else { return true }
        guard let command = SlashCommandCatalog.command(named: String(body[body.startIndex..<space])) else {
            return false
        }
        return command.subArgs != .none
    }

    private static func isWhitespaceOrNewline(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isNewline(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }
}
