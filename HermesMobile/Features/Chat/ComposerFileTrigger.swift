import Foundation

struct ComposerFileTrigger: Equatable {
    let range: NSRange
    let text: String

    var query: String { String(text.dropFirst()) }

    private static let at: UInt16 = 0x40

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
