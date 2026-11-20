import SwiftUI

enum MarkdownDiffLineKind: Equatable {
    case added
    case removed
    case context
    case hunk
    case fileHeader
    case note
}

struct MarkdownDiffLine: Equatable, Identifiable {
    let id: Int
    let kind: MarkdownDiffLineKind
    let text: String
    let segments: [MarkdownPlainCodeSegment]
}

struct MarkdownDiffDocument: Equatable {
    let lines: [MarkdownDiffLine]
    let additions: Int
    let deletions: Int

    var isCollapsible: Bool { lines.count > MarkdownDiffFormatter.collapsedLineLimit }

    func visibleLines(showingAll: Bool) -> [MarkdownDiffLine] {
        isCollapsible && !showingAll ? Array(lines.prefix(MarkdownDiffFormatter.collapsedLineLimit)) : lines
    }
}

enum MarkdownDiffFormatter {
    static let collapsedLineLimit = 80

    private static let languages: Set<String> = ["diff", "patch"]
    private static let fileHeaderPrefixes = [
        "diff ",
        "index ",
        "--- ",
        "+++ ",
        "new file mode",
        "deleted file mode",
        "old mode",
        "new mode",
        "rename from",
        "rename to",
        "similarity index",
        "dissimilarity index",
        "copy from",
        "copy to"
    ]

    static func isDiffLanguage(_ language: String?) -> Bool {
        guard let normalized = MarkdownHighlightPolicy.normalizedLanguage(from: language) else { return false }
        return languages.contains(normalized)
    }

    static func document(for code: String, language: String?, isStreaming: Bool) -> MarkdownDiffDocument? {
        guard !isStreaming,
              let normalized = MarkdownHighlightPolicy.normalizedLanguage(from: language),
              languages.contains(normalized)
        else { return nil }

        let key = code as NSString
        if let cached = cache.object(forKey: key) { return cached.document }
        let document = fitsSizeGuards(code) ? parse(code) : nil
        if let document { cache.setObject(CacheBox(document), forKey: key) }
        return document
    }

    static func fitsSizeGuards(_ code: String) -> Bool {
        MarkdownHighlightPolicy.decision(for: code, language: "diff", isStreaming: false)
            == .plain(reason: .highRiskLanguage, normalizedLanguage: "diff")
    }

    private static let cache: NSCache<NSString, CacheBox> = {
        let cache = NSCache<NSString, CacheBox>()
        cache.countLimit = 64
        return cache
    }()

    private final class CacheBox {
        let document: MarkdownDiffDocument
        init(_ document: MarkdownDiffDocument) { self.document = document }
    }

    static func parse(_ code: String) -> MarkdownDiffDocument {
        var lines: [MarkdownDiffLine] = []
        var additions = 0
        var deletions = 0
        var remaining: (old: Int, new: Int)?

        for (index, text) in MarkdownPlainCodeFormatter.rawLines(in: code).enumerated() {
            let kind: MarkdownDiffLineKind
            if text.hasPrefix("@@") {
                kind = .hunk
                remaining = hunkCounts(in: text).flatMap { $0.old > 0 || $0.new > 0 ? $0 : nil }
            } else if var counts = remaining, let counted = countedKind(of: text) {
                kind = counted
                switch counted {
                case .added: counts.new -= 1
                case .removed: counts.old -= 1
                case .context: counts.old -= 1; counts.new -= 1
                case .hunk, .fileHeader, .note: break
                }
                remaining = counts.old <= 0 && counts.new <= 0 ? nil : counts
            } else {
                remaining = nil
                kind = uncountedKind(of: text)
            }

            switch kind {
            case .added: additions += 1
            case .removed: deletions += 1
            case .context, .hunk, .fileHeader, .note: break
            }
            lines.append(
                MarkdownDiffLine(
                    id: index,
                    kind: kind,
                    text: text,
                    segments: MarkdownPlainCodeFormatter.segments(in: text)
                )
            )
        }

        return MarkdownDiffDocument(lines: lines, additions: additions, deletions: deletions)
    }

    private static func countedKind(of line: String) -> MarkdownDiffLineKind? {
        switch line.first {
        case "+": .added
        case "-": .removed
        case " ", nil: .context
        case "\\": .note
        default: nil
        }
    }

    private static func uncountedKind(of line: String) -> MarkdownDiffLineKind {
        if fileHeaderPrefixes.contains(where: line.hasPrefix) { return .fileHeader }
        switch line.first {
        case "+": return .added
        case "-": return .removed
        case "\\": return .note
        default: return .context
        }
    }

    private static func hunkCounts(in line: String) -> (old: Int, new: Int)? {
        let scanner = Scanner(string: line)
        guard scanner.scanString("@@") != nil,
              scanner.scanString("-") != nil,
              scanner.scanInt() != nil else { return nil }
        let old = scanner.scanString(",") != nil ? scanner.scanInt() : 1
        guard let old,
              scanner.scanString("+") != nil,
              scanner.scanInt() != nil else { return nil }
        let new = scanner.scanString(",") != nil ? scanner.scanInt() : 1
        guard let new, scanner.scanString("@@") != nil else { return nil }
        return (max(old, 0), max(new, 0))
    }
}

struct DiffCodeBlockScrollBody: View {
    let lines: [MarkdownDiffLine]

    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            DiffCodeBlockText(lines: lines, minRowWidth: viewportWidth)
                .fixedSize(horizontal: true, vertical: true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }
}

struct DiffCodeBlockText: View {
    let lines: [MarkdownDiffLine]
    var wraps = false
    var minRowWidth: CGFloat = 0

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(CodeDisplaySettings.customSizeKey) private var customCodeSize: Double?

    private static let theme = ReviewDiffTheme()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                rowText(for: line)
                    .foregroundStyle(Self.isMuted(line.kind) ? SwiftUI.Color(.appTextSecondary) : SwiftUI.Color(.appText))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 1.5)
                    .frame(minWidth: minRowWidth, maxWidth: .infinity, alignment: .leading)
                    .background(Self.background(for: line.kind))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.accessibilityLabel(for: line))
            }
        }
        .font(ChatTypography(dynamicTypeSize: dynamicTypeSize).codeFont(customSize: customCodeSize))
    }

    @ViewBuilder
    private func rowText(for line: MarkdownDiffLine) -> some View {
        if wraps {
            line.segments
                .reduce(Text(verbatim: "")) { partial, segment in partial + Text(verbatim: segment.text) }
                .responseSelectableText(line.segments.map(\.text).joined())
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(line.segments) { segment in
                    Text(verbatim: segment.text)
                        .responseSelectableText(segment.text, separator: segment.id == line.segments.last?.id ? "\n" : "")
                }
            }
        }
    }

    private static func isMuted(_ kind: MarkdownDiffLineKind) -> Bool {
        switch kind {
        case .hunk, .fileHeader, .note: true
        case .added, .removed, .context: false
        }
    }

    private static func background(for kind: MarkdownDiffLineKind) -> SwiftUI.Color {
        switch kind {
        case .added: SwiftUI.Color(uiColor: theme.addBackground)
        case .removed: SwiftUI.Color(uiColor: theme.deleteBackground)
        case .hunk: SwiftUI.Color(uiColor: theme.hunkBackground)
        case .context, .fileHeader, .note: .clear
        }
    }

    static func accessibilityLabel(for line: MarkdownDiffLine) -> String {
        let change: String
        switch line.kind {
        case .added: change = String(localized: "added")
        case .removed: change = String(localized: "removed")
        case .context, .hunk, .fileHeader, .note: return line.text.isEmpty ? String(localized: "blank") : line.text
        }
        let content = String(line.text.dropFirst())
        return change + ", " + (content.isEmpty ? String(localized: "blank") : content)
    }
}
