import Foundation
import SwiftUI

/// A skill reference in the draft that the composer draws as one atomic chip.
///
/// `range` and `source` are always in draft coordinates. The chip is a picture
/// of `source`, never a replacement for it, so what the server receives and what
/// the draft store keeps is exactly the text the user would have typed.
struct ComposerChipToken: Equatable {
    /// UTF-16 range of the reference inside the draft.
    let range: NSRange
    /// The exact draft substring the chip stands for, `/` included.
    let source: String
    /// What the chip reads on screen.
    let label: String
}

/// The skills a draft can reference, in the shape the tokenizer needs.
///
/// Built from the composer's skill suggestions once and compared by value, so
/// the editor only redraws when the server's skill list has actually changed.
struct ComposerChipCatalog: Equatable {
    /// Lowercased slug to chip label.
    private let labelsBySlug: [String: String]

    static let empty = ComposerChipCatalog(labelsBySlug: [:])

    private init(labelsBySlug: [String: String]) {
        self.labelsBySlug = labelsBySlug
    }

    /// A slug that is also a built-in command is left out: `/model` is the
    /// command, whatever a server happens to call its skills.
    init(skills: [SkillSlashSuggestion]) {
        var labels: [String: String] = [:]
        for skill in skills {
            let slug = skill.slashName.lowercased()
            guard !slug.isEmpty, !SlashCommandCatalog.builtinNames.contains(slug) else { continue }
            labels[slug] = skill.name
        }
        labelsBySlug = labels
    }

    var isEmpty: Bool { labelsBySlug.isEmpty }

    func label(forSlug slug: String) -> String? {
        labelsBySlug[slug.lowercased()]
    }
}

/// Finds the skill references in a draft. Pure: the same draft and catalog
/// always produce the same chips, which is what lets a pasted or restored draft
/// come back with its chips intact without storing anything beside the text.
enum ComposerChipTokenizer {
    private static let slash: UInt16 = 0x2F

    /// Every skill reference in `draft` worth drawing as a chip.
    ///
    /// A reference is a `/` that starts the draft or follows whitespace, a slug
    /// the server knows, and whitespace after it. The trailing whitespace is
    /// what says the user is done typing the name, so a half-typed `/ask-ma`
    /// stays ordinary editable text. `previous` keeps a chip at the very end of
    /// the draft drawn after its trailing space is deleted, so backspacing the
    /// space a completion added does not flicker the chip back into text.
    ///
    /// `isComplete` says the text is finished rather than being typed, which is
    /// what a sent message is: a reference that ends the message is a whole
    /// reference, so the transcript draws the chip the composer was still
    /// waiting for a space to confirm.
    static func tokens(
        in draft: String,
        catalog: ComposerChipCatalog,
        preservingTrailing previous: [ComposerChipToken] = [],
        isComplete: Bool = false
    ) -> [ComposerChipToken] {
        guard !catalog.isEmpty else { return [] }

        let text = draft as NSString
        var tokens: [ComposerChipToken] = []
        var index = 0

        while index < text.length {
            guard text.character(at: index) == slash,
                  index == 0 || isWhitespaceOrNewline(text.character(at: index - 1))
            else {
                index += 1
                continue
            }

            var end = index + 1
            while end < text.length, isSlugUnit(text.character(at: end)) {
                end += 1
            }

            guard end > index + 1 else {
                index += 1
                continue
            }

            let range = NSRange(location: index, length: end - index)
            let source = text.substring(with: range)
            index = end

            guard let label = catalog.label(forSlug: String(source.dropFirst())) else { continue }

            let isClosed = end < text.length && isWhitespaceOrNewline(text.character(at: end))
            let isPreservedTail = end == text.length
                && (isComplete || previous.contains { $0.range == range && $0.source == source })
            guard isClosed || isPreservedTail else { continue }

            tokens.append(ComposerChipToken(range: range, source: source, label: label))
        }

        return tokens
    }

    /// `draft` with every chip reference replaced by the chip's label, which is
    /// what VoiceOver should read: the editor's attachments carry the same
    /// label, so both composer states are heard the same way.
    static func spokenText(in draft: String, tokens: [ComposerChipToken]) -> String {
        guard !tokens.isEmpty else { return draft }

        let text = draft as NSString
        let spoken = NSMutableString()
        var cursor = 0

        for token in tokens where token.range.location >= cursor {
            if token.range.location > cursor {
                spoken.append(
                    text.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
                )
            }
            spoken.append(token.label)
            cursor = token.range.upperBound
        }

        if cursor < text.length {
            spoken.append(text.substring(from: cursor))
        }

        return spoken as String
    }

    /// Whether `draft` holds anything that could become a chip once the skill
    /// list arrives. The composer uses it to warm that list for a restored
    /// draft instead of fetching skills every time a chat opens.
    static func mayContainReference(_ draft: String) -> Bool {
        let text = draft as NSString
        var index = 0

        while index < text.length - 1 {
            if text.character(at: index) == slash,
               index == 0 || isWhitespaceOrNewline(text.character(at: index - 1)),
               isSlugUnit(text.character(at: index + 1)) {
                return true
            }
            index += 1
        }

        return false
    }

    /// The characters a skill slug is made of. `SlashSkillFormatter.slug`
    /// only ever emits lowercase letters, digits, and hyphens; the rest are
    /// accepted so a hand-typed `/Ask_Matt` is scanned as one word and rejected
    /// by the catalog rather than cut in half.
    private static func isSlugUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
            || scalar == "-"
            || scalar == "_"
    }

    private static func isWhitespaceOrNewline(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

private struct SkillChipCatalogKey: EnvironmentKey {
    static let defaultValue = ComposerChipCatalog.empty
}

extension EnvironmentValues {
    /// The skills a transcript may draw as chips.
    ///
    /// Sent messages carry no marker for a reference, so the bubble has to look
    /// the slug up the same way the composer does. It travels in the
    /// environment because it belongs to the chat, not to any one bubble, and
    /// the rows in between are `Equatable` blocks that should not have to
    /// forward it.
    var skillChipCatalog: ComposerChipCatalog {
        get { self[SkillChipCatalogKey.self] }
        set { self[SkillChipCatalogKey.self] = newValue }
    }
}
