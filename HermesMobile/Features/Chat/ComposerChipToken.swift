import Foundation

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
    static func tokens(
        in draft: String,
        catalog: ComposerChipCatalog,
        preservingTrailing previous: [ComposerChipToken] = []
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
                && previous.contains { $0.range == range && $0.source == source }
            guard isClosed || isPreservedTail else { continue }

            tokens.append(ComposerChipToken(range: range, source: source, label: label))
        }

        return tokens
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
