import Foundation
import SwiftUI

enum ComposerChipKind: Equatable {
    case skill
    case file
    case bot(ComposerBotReference)
}

enum ComposerChipIcon: Equatable {
    case symbol(String)
    case asset(String)
    case bot(ComposerBotReference)

    var cacheKey: NSObject {
        switch self {
        case let .symbol(name):
            return "symbol:\(name)" as NSString
        case let .asset(name):
            return "asset:\(name)" as NSString
        case let .bot(reference):
            let look = BotProfileAppearance(profile: reference.profile)
            return ["kind": "bot", "profile": reference.profile.id,
                    "shape": look.shape ?? "", "color": look.color ?? "", "custom": look.custom,
                    "expression": look.expression ?? "", "generated": look.generated.map { String(describing: $0) } ?? "", "image": (reference.avatar as NSObject?) ?? NSNull()] as NSDictionary
        }
    }
}

struct ComposerBotReference: Equatable {
    let profile: BotProfile
    let avatar: UIImage?
}

struct ComposerChipToken: Equatable {
    let range: NSRange
    let source: String
    let label: String
    let kind: ComposerChipKind

    private static let skillSymbol = "hammer"

    var icon: ComposerChipIcon {
        switch kind {
        case .skill:
            return .symbol(Self.skillSymbol)
        case .file:
            return .asset(FileIcon.resolve(label).assetName)
        case let .bot(reference):
            return .bot(reference)
        }
    }

    var filePath: String? {
        guard kind == .file else { return nil }
        return String(source.dropFirst())
    }
}

struct ComposerChipCatalog: Equatable {
    private let labelsBySlug: [String: String]
    private let filePaths: Set<String>
    let bots: [String: ComposerBotReference]

    static let empty = ComposerChipCatalog(labelsBySlug: [:], filePaths: [])

    private init(labelsBySlug: [String: String], filePaths: Set<String>, bots: [String: ComposerBotReference] = [:]) {
        self.bots = bots
        self.labelsBySlug = labelsBySlug
        self.filePaths = filePaths
    }

    init(skills: [SkillSlashSuggestion], filePaths: Set<String> = [], bots: [String: ComposerBotReference] = [:]) {
        self.bots = bots
        var labels: [String: String] = [:]
        for skill in skills {
            let slug = skill.slashName.lowercased()
            guard !slug.isEmpty, !SlashCommandCatalog.builtinNames.contains(slug) else { continue }
            labels[slug] = skill.name
        }
        labelsBySlug = labels
        self.filePaths = filePaths
    }

    var isEmpty: Bool { labelsBySlug.isEmpty && filePaths.isEmpty && bots.isEmpty }

    func label(forSlug slug: String) -> String? {
        labelsBySlug[slug.lowercased()]
    }

    func containsFile(path: String) -> Bool {
        filePaths.contains(path)
    }

    func withFilePaths(_ paths: Set<String>) -> ComposerChipCatalog {
        ComposerChipCatalog(labelsBySlug: labelsBySlug, filePaths: paths, bots: bots)
    }
}

enum ComposerChipTokenizer {
    private static let slash: UInt16 = 0x2F
    private static let at: UInt16 = 0x40

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

        if !catalog.bots.isEmpty {
            for mention in BotMentions.proseMentions(in: draft) {
                guard let bot = catalog.bots[mention.form] else { continue }
                let range = mention.range
                let source = text.substring(with: range)
                let end = range.upperBound
                let isClosed = end < text.length && isWhitespaceOrNewline(text.character(at: end))
                let isPreservedTail = end == text.length
                    && (isComplete || previous.contains { $0.range == range && $0.source == source })
                guard isClosed || isPreservedTail,
                      !tokens.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
                tokens.append(ComposerChipToken(range: range, source: source, label: bot.profile.name, kind: .bot(bot)))
            }
            tokens.sort { $0.range.location < $1.range.location }
        }
        return tokens
    }

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
    var composerChipCatalog: ComposerChipCatalog {
        get { self[ComposerChipCatalogKey.self] }
        set { self[ComposerChipCatalogKey.self] = newValue }
    }
}
