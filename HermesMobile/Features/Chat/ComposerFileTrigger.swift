import Foundation

/// The `@…` run the caret is sitting in, if there is one.
///
/// Typing `@` opens the workspace file panel the way `/` opens the command
/// panel. The trigger is found at the caret and reports the range it occupies,
/// so accepting a row replaces only that much and the rest of the draft
/// survives.
struct ComposerFileTrigger: Equatable {
    /// UTF-16 range of the trigger inside the draft: the `@` up to the caret.
    let range: NSRange
    /// The trigger's text, `@` included.
    let text: String

    /// The workspace path typed so far, without the `@`. This is what the panel
    /// lists and filters on.
    var query: String { String(text.dropFirst()) }

    private static let at: UInt16 = 0x40

    /// The trigger `selection` sits in, or `nil` when there is none.
    ///
    /// A trigger is an `@` that starts the draft or follows whitespace, running
    /// forward to the caret and never across whitespace or a line break. Those
    /// two rules together are what keep an email address out: the `@` in
    /// `foo@bar` follows a letter, and the scan stops at the space in front of
    /// `foo` rather than looking further back. A selection with a length is
    /// never a trigger: the user is selecting text, not naming a file.
    static func detect(in draft: String, selection: NSRange) -> ComposerFileTrigger? {
        guard selection.length == 0 else { return nil }

        let draft = draft as NSString
        let caret = selection.location
        guard caret >= 0, caret <= draft.length else { return nil }

        var index = caret - 1
        while index >= 0 {
            let unit = draft.character(at: index)
            if isWhitespaceOrNewline(unit) { return nil }

            if unit == Self.at, index == 0 || isWhitespaceOrNewline(draft.character(at: index - 1)) {
                let range = NSRange(location: index, length: caret - index)
                return ComposerFileTrigger(range: range, text: draft.substring(with: range))
            }

            index -= 1
        }

        return nil
    }

    /// What the draft and caret become when the user accepts `replacement`.
    ///
    /// Only the trigger's own range changes. When the completion wants a
    /// trailing space and the draft already has one waiting there, the space is
    /// dropped and the caret steps over the existing one instead, so accepting a
    /// file mid-sentence leaves neither a double space nor a caret stranded in
    /// front of one. Deliberately the same arithmetic as
    /// `ComposerSlashTrigger.applying(_:to:)`, which owns the `/` panel.
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

    private static func isWhitespaceOrNewline(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }
}
