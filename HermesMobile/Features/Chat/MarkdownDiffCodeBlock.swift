import SwiftUI

/// What one line of a ```diff or ```patch fence is.
enum MarkdownDiffLineKind: Equatable {
    case added
    case removed
    case context
    case hunk
    case fileHeader
    /// `\ No newline at end of file`: metadata that counts toward neither side.
    case note
}

struct MarkdownDiffLine: Equatable, Identifiable {
    let id: Int
    let kind: MarkdownDiffLineKind
    let text: String
    /// The same 500-character segments `PlainCodeBlockText` draws, so a long line stays cheap to lay out.
    let segments: [MarkdownPlainCodeSegment]
}

struct MarkdownDiffDocument: Equatable {
    let lines: [MarkdownDiffLine]
    let additions: Int
    let deletions: Int

    /// Whether the block is long enough to collapse to `collapsedLineLimit` lines.
    var isCollapsible: Bool { lines.count > MarkdownDiffFormatter.collapsedLineLimit }

    /// The rows to draw: every line when expanded or short, otherwise the first `collapsedLineLimit`.
    func visibleLines(showingAll: Bool) -> [MarkdownDiffLine] {
        isCollapsible && !showingAll ? Array(lines.prefix(MarkdownDiffFormatter.collapsedLineLimit)) : lines
    }
}

/// Classifies the lines of a diff or patch fence by prefix in one pass on the main
/// actor, so chat tints them natively and never sends them through Highlightr.
/// Handles git and plain `diff -u` output, multi-file patches with or without
/// `diff --git` lines, and hand-written diffs with bare or missing `@@` headers.
enum MarkdownDiffFormatter {
    /// A settled diff block shows this many lines until the reader expands it.
    static let collapsedLineLimit = 80

    private static let languages: Set<String> = ["diff", "patch"]
    /// Lines outside a counted hunk that describe a file rather than change it.
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

    /// Whether a fence language is diff or patch. Reads only the language, so it is a cheap gate.
    static func isDiffLanguage(_ language: String?) -> Bool {
        guard let normalized = MarkdownHighlightPolicy.normalizedLanguage(from: language) else { return false }
        return languages.contains(normalized)
    }

    /// The styled document for a code fence, or nil when the fence renders as plain code:
    /// it is still streaming, is not diff or patch, is empty, or is past the highlighter's
    /// size guards (characters, lines, line length).
    static func document(for code: String, language: String?, isStreaming: Bool) -> MarkdownDiffDocument? {
        guard !isStreaming,
              let normalized = MarkdownHighlightPolicy.normalizedLanguage(from: language),
              languages.contains(normalized),
              // Diff reaches `.highRiskLanguage` only after the empty and size guards pass.
              MarkdownHighlightPolicy.decision(for: code, language: normalized, isStreaming: false)
                == .plain(reason: .highRiskLanguage, normalizedLanguage: normalized)
        else { return nil }
        return parse(code)
    }

    /// Classifies every line. An `@@ -a,b +c,d @@` header opens a hunk whose counts
    /// bound it, so a counted `--- x` or `+++ y` line is a change, and the next file's
    /// `---`/`+++` lines are headers once the counts run out. Outside a counted hunk
    /// (before the first `@@`, after a bare `@@`, or past the counts), prefix rules
    /// apply with `--- `/`+++ ` and git's metadata lines read as file headers.
    static func parse(_ code: String) -> MarkdownDiffDocument {
        var lines: [MarkdownDiffLine] = []
        var additions = 0
        var deletions = 0
        // Old and new lines left in the current counted hunk; nil outside one.
        var remaining: (old: Int, new: Int)?

        for (index, text) in MarkdownPlainCodeFormatter.rawLines(in: code).enumerated() {
            let kind: MarkdownDiffLineKind
            if text.hasPrefix("@@") {
                kind = .hunk
                remaining = hunkCounts(in: text).flatMap { $0.old + $0.new > 0 ? $0 : nil }
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

    /// Inside a counted hunk the first character alone decides; nil for a line that
    /// cannot belong to a hunk, which ends it. An empty line is context whose space
    /// was trimmed.
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

    /// The old and new line counts of `@@ -a[,b] +c[,d] @@`, where an omitted count
    /// means 1. Nil for a bare `@@` or any header that does not parse.
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

/// The horizontal-scroll layout of a settled diff. It owns the viewport width so the
/// post-layout width write re-renders only this view, not `ChatCodeBlock` (which
/// would re-parse the diff).
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

/// The settled body of a diff fence inside `ChatCodeBlock`: one row per line, tinted
/// edge to edge by kind with the text kept primary and the `+`/`-` prefix visible,
/// so color is never the only signal. Tints match the Git review sheet.
struct DiffCodeBlockText: View {
    let lines: [MarkdownDiffLine]
    /// See `PlainCodeBlockText.wraps`.
    var wraps = false
    /// The scroll viewport's width in the horizontal-scroll layout, so a short line's
    /// tint still reaches the block's trailing edge.
    var minRowWidth: CGFloat = 0

    private static let theme = ReviewDiffTheme()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                rowText(for: line)
                    .foregroundStyle(Self.isMuted(line.kind) ? SwiftUI.Color.secondary : SwiftUI.Color.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 1.5)
                    .frame(minWidth: minRowWidth, maxWidth: .infinity, alignment: .leading)
                    .background(Self.background(for: line.kind))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.accessibilityLabel(for: line))
            }
        }
        .font(.system(size: 13, weight: .regular, design: .monospaced))
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

    /// "added, <text>" / "removed, <text>" without the prefix, like the review sheet's rows.
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
