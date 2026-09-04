import UIKit

/// Where the composer's caret is, and whose idea that was.
///
/// The range is reported up on every edit and caret move, so the composer can
/// tell what the user is typing *at*. `revision` moves only when the composer
/// deliberately places the caret — accepting a slash completion is the one case
/// — so an update replaying an older value can never yank the caret back.
struct ComposerSelection: Equatable {
    var range = NSRange(location: 0, length: 0)
    var revision = 0

    /// A caret the composer is moving on purpose.
    func moved(to range: NSRange) -> ComposerSelection {
        ComposerSelection(range: range, revision: revision &+ 1)
    }
}

/// When a bound draft may overwrite a live IME composition.
enum ComposerMarkedText {
    /// Whether `boundText` is a real replacement rather than an echo of what the
    /// editor has already committed.
    ///
    /// While an IME composition is marked, assigning text commits it half-formed
    /// and splits characters such as 자 into ㅈㅏ (#312). A parent that has
    /// simply not seen the marked text yet is echoing the committed draft back,
    /// which is not a change worth breaking a composition for. A deliberate
    /// clear or replacement still is.
    static func isDeliberateReplacement(_ boundText: String, editorText: String, marked: NSRange) -> Bool {
        let editor = editorText as NSString
        guard marked.location >= 0, marked.length >= 0, marked.upperBound <= editor.length else {
            return boundText != editorText
        }

        return boundText != editorText && boundText != editor.replacingCharacters(in: marked, with: "")
    }
}

/// One replacement that turns the editor's text into the text the composer wants.
///
/// Applying it through `UITextView.replace(_:withText:)` keeps the change on the
/// editor's undo stack and leaves the rest of the draft untouched, neither of
/// which assigning `text` wholesale does.
struct ComposerTextEdit: Equatable {
    /// UTF-16 range to replace, in the editor's current text.
    let range: NSRange
    let replacement: String

    /// The smallest edit from `current` to `target`, or `nil` when they match.
    static func between(current: String, target: String) -> ComposerTextEdit? {
        guard current != target else { return nil }

        let current = current as NSString
        let target = target as NSString
        let shortest = min(current.length, target.length)

        var prefix = 0
        while prefix < shortest, current.character(at: prefix) == target.character(at: prefix) {
            prefix += 1
        }

        var suffix = 0
        while suffix < shortest - prefix,
              current.character(at: current.length - 1 - suffix) == target.character(at: target.length - 1 - suffix) {
            suffix += 1
        }

        // A range that cuts a surrogate pair in half has no `UITextRange`, so
        // back the boundary off onto the character it belongs to.
        if prefix > 0, isTrailingSurrogate(at: prefix, in: current) || isTrailingSurrogate(at: prefix, in: target) {
            prefix -= 1
        }
        if suffix > 0, isTrailingSurrogate(at: current.length - suffix, in: current) {
            suffix -= 1
        }

        return ComposerTextEdit(
            range: NSRange(location: prefix, length: current.length - prefix - suffix),
            replacement: target.substring(with: NSRange(location: prefix, length: target.length - prefix - suffix))
        )
    }

    private static func isTrailingSurrogate(at index: Int, in text: NSString) -> Bool {
        guard index >= 0, index < text.length else { return false }
        return UTF16.isTrailSurrogate(text.character(at: index))
    }
}

extension UITextView {
    /// The `UITextRange` for a UTF-16 range, or `nil` when it does not land on
    /// positions this editor recognises.
    func textRange(from range: NSRange) -> UITextRange? {
        guard range.location >= 0, range.length >= 0, range.upperBound <= (text as NSString).length else {
            return nil
        }
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length)
        else {
            return nil
        }
        return textRange(from: start, to: end)
    }
}
