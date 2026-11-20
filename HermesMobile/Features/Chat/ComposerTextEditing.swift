import UIKit

struct ComposerSelection: Equatable {
    var range = NSRange(location: 0, length: 0)
    var revision = 0
    var publishGeneration = 0

    func moved(to range: NSRange) -> ComposerSelection {
        ComposerSelection(range: range, revision: revision &+ 1, publishGeneration: publishGeneration)
    }
}

enum ComposerMarkedText {
    static func isDeliberateReplacement(
        _ boundText: String,
        editorText: String,
        marked: NSRange,
        isCurrent: Bool
    ) -> Bool {
        guard boundText != editorText else { return false }
        guard !boundText.isEmpty else { return isCurrent }

        let editor = editorText as NSString
        guard marked.location >= 0, marked.length >= 0, marked.upperBound <= editor.length else {
            return true
        }

        return boundText != editor.replacingCharacters(in: marked, with: "")
    }
}

struct ComposerTextEdit: Equatable {
    let range: NSRange
    let replacement: String

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
