import Foundation
import SwiftUI

/// What a chip stands for. The kind picks the glyph and decides whether tapping
/// the chip does anything: a file opens on the source viewer, a skill is inert.
enum ComposerChipKind: Equatable {
    case skill
    case file
}

/// The picture inside a chip.
///
/// A skill draws an SF Symbol in the chip's own muted tint. A file draws the
/// full-colour glyph the file tree already uses for its type, so one file reads
/// the same in the composer, the workspace, and the transcript.
enum ComposerChipIcon: Equatable {
    case symbol(String)
    case asset(String)

    /// Stable text for the renderer's image cache key.
    var cacheKey: String {
        switch self {
        case let .symbol(name):
            return "symbol:\(name)"
        case let .asset(name):
            return "asset:\(name)"
        }
    }
}

/// A skill or workspace-file reference in the draft that the composer draws as
/// one atomic chip.
///
/// `range` and `source` are always in draft coordinates. The chip is a picture
/// of `source`, never a replacement for it, so what the server receives and what
/// the draft store keeps is exactly the text the user would have typed.
struct ComposerChipToken: Equatable {
    /// UTF-16 range of the reference inside the draft.
    let range: NSRange
    /// The exact draft substring the chip stands for, `/` or `@` included.
    let source: String
    /// What the chip reads on screen: a skill's name, or a file's last path
    /// component.
    let label: String
    let kind: ComposerChipKind

    /// Matches the Skills screen's own glyph so a skill chip reads as the same
    /// thing the rest of the app calls a skill.
    private static let skillSymbol = "hammer"

    /// Derived rather than stored so a chip's picture can never drift from what
    /// the chip stands for.
    var icon: ComposerChipIcon {
        switch kind {
        case .skill:
            return .symbol(Self.skillSymbol)
        case .file:
            return .asset(FileIcon.resolve(label).assetName)
        }
    }

    /// The workspace-relative path a file chip names, or `nil` for a skill.
    var filePath: String? {
        guard kind == .file else { return nil }
        return String(source.dropFirst())
    }
}

/// The references a draft can draw as chips, in the shape the tokenizer needs.
///
/// Built from the composer's skill suggestions and the workspace files the user
/// has picked, and compared by value, so the editor only redraws when one of
/// those two lists has actually changed.
struct ComposerChipCatalog: Equatable {
    /// Lowercased slug to chip label.
    private let labelsBySlug: [String: String]
    /// Workspace-relative paths, exactly as the server spells them.
    private let filePaths: Set<String>

    static let empty = ComposerChipCatalog(labelsBySlug: [:], filePaths: [])

    private init(labelsBySlug: [String: String], filePaths: Set<String>) {
        self.labelsBySlug = labelsBySlug
        self.filePaths = filePaths
    }

    /// A slug that is also a built-in command is left out: `/model` is the
    /// command, whatever a server happens to call its skills.
    init(skills: [SkillSlashSuggestion], filePaths: Set<String> = []) {
        var labels: [String: String] = [:]
        for skill in skills {
            let slug = skill.slashName.lowercased()
            guard !slug.isEmpty, !SlashCommandCatalog.builtinNames.contains(slug) else { continue }
            labels[slug] = skill.name
        }
        labelsBySlug = labels
        self.filePaths = filePaths
    }

    var isEmpty: Bool { labelsBySlug.isEmpty && filePaths.isEmpty }

    func label(forSlug slug: String) -> String? {
        labelsBySlug[slug.lowercased()]
    }

    /// Paths are compared exactly: the server's filesystem decides case, and a
    /// path the app has never been handed is not a reference.
    func containsFile(path: String) -> Bool {
        filePaths.contains(path)
    }

    /// The same skills with `paths` as the files a chip may be drawn for.
    func withFilePaths(_ paths: Set<String>) -> ComposerChipCatalog {
        ComposerChipCatalog(labelsBySlug: labelsBySlug, filePaths: paths)
    }
}

/// Finds the references in a draft. Pure: the same draft and catalog always
/// produce the same chips, which is what lets a pasted or restored draft come
/// back with its chips intact without storing anything beside the text.
enum ComposerChipTokenizer {
    private static let slash: UInt16 = 0x2F
    private static let at: UInt16 = 0x40

    /// Every reference in `draft` worth drawing as a chip.
    ///
    /// A reference is a `/` or `@` that starts the draft or follows whitespace,
    /// a name the catalog knows, and whitespace after it. A skill's name runs to
    /// the end of its slug; a file's path runs to the next whitespace, because a
    /// path is one unbroken word. The trailing whitespace is what says the user
    /// is done typing, so a half-typed `/ask-ma` or `@src/Cha` stays ordinary
    /// editable text. `previous` keeps a chip at the very end of the draft drawn
    /// after its trailing space is deleted, so backspacing the space a
    /// completion added does not flicker the chip back into text.
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
            let marker = text.character(at: index)
            guard marker == slash || marker == at,
                  index == 0 || isWhitespaceOrNewline(text.character(at: index - 1))
            else {
                index += 1
                continue
            }

            var end = index + 1
            while end < text.length, isBodyUnit(text.character(at: end), after: marker) {
                end += 1
            }

            guard end > index + 1 else {
                index += 1
                continue
            }

            let range = NSRange(location: index, length: end - index)
            let source = text.substring(with: range)
            index = end

            let body = String(source.dropFirst())
            let kind: ComposerChipKind
            let label: String
            if marker == slash {
                guard let skillLabel = catalog.label(forSlug: body) else { continue }
                kind = .skill
                label = skillLabel
            } else {
                guard catalog.containsFile(path: body) else { continue }
                kind = .file
                label = String(body.split(separator: "/").last ?? Substring(body))
            }

            let isClosed = end < text.length && isWhitespaceOrNewline(text.character(at: end))
            let isPreservedTail = end == text.length
                && (isComplete || previous.contains { $0.range == range && $0.source == source })
            guard isClosed || isPreservedTail else { continue }

            tokens.append(ComposerChipToken(range: range, source: source, label: label, kind: kind))
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

    /// Every `@…` run in `text` that could name a workspace file, in the order
    /// they appear and without repeats.
    ///
    /// Deliberately the same scan the tokenizer uses — an `@` that starts the
    /// text or follows whitespace, running to the next whitespace — and
    /// deliberately without a "looks like a filename" heuristic. Whether a
    /// candidate is a file is the server's answer to give, and guessing here
    /// would mean a real reference silently failing to draw.
    ///
    /// `isComplete` carries the tokenizer's meaning: without it a reference that
    /// ends the text is still being typed, so `@sr` on the way to `@src/x.swift`
    /// is not offered as something to look up.
    static func fileReferenceCandidates(in text: String, isComplete: Bool = false) -> [String] {
        let text = text as NSString
        var candidates: [String] = []
        var seen: Set<String> = []
        var index = 0

        while index < text.length {
            guard text.character(at: index) == at,
                  index == 0 || isWhitespaceOrNewline(text.character(at: index - 1))
            else {
                index += 1
                continue
            }

            var end = index + 1
            while end < text.length, isBodyUnit(text.character(at: end), after: at) {
                end += 1
            }

            let path = text.substring(with: NSRange(location: index + 1, length: end - index - 1))
            let isClosed = end < text.length || isComplete
            index = end

            guard isClosed, !path.isEmpty, seen.insert(path).inserted else { continue }
            candidates.append(path)
        }

        return candidates
    }

    /// Whether `draft` holds anything that could become a chip once the skill
    /// list or the session's picked files arrive. The composer uses it to warm
    /// that list for a restored draft instead of fetching skills every time a
    /// chat opens.
    static func mayContainReference(_ draft: String) -> Bool {
        let text = draft as NSString
        var index = 0

        while index < text.length - 1 {
            let marker = text.character(at: index)
            if marker == slash || marker == at,
               index == 0 || isWhitespaceOrNewline(text.character(at: index - 1)),
               isBodyUnit(text.character(at: index + 1), after: marker) {
                return true
            }
            index += 1
        }

        return false
    }

    /// Whether `unit` continues a reference opened by `marker`.
    ///
    /// A file path is any run of non-whitespace, since `/`, `.`, and `-` are all
    /// ordinary path characters. A skill slug is narrower: `SlashSkillFormatter`
    /// only ever emits lowercase letters, digits, and hyphens, and the rest are
    /// accepted so a hand-typed `/Ask_Matt` is scanned as one word and rejected
    /// by the catalog rather than cut in half.
    private static func isBodyUnit(_ unit: UInt16, after marker: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        guard marker == slash else {
            return !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        return CharacterSet.alphanumerics.contains(scalar)
            || scalar == "-"
            || scalar == "_"
    }

    private static func isWhitespaceOrNewline(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

private struct ComposerChipCatalogKey: EnvironmentKey {
    static let defaultValue = ComposerChipCatalog.empty
}

extension EnvironmentValues {
    /// The skills and workspace files a transcript may draw as chips.
    ///
    /// Sent messages carry no marker for a reference, so the bubble has to look
    /// the slug or path up the same way the composer does. It travels in the
    /// environment because it belongs to the chat, not to any one bubble, and
    /// the rows in between are `Equatable` blocks that should not have to
    /// forward it.
    var composerChipCatalog: ComposerChipCatalog {
        get { self[ComposerChipCatalogKey.self] }
        set { self[ComposerChipCatalogKey.self] = newValue }
    }
}
