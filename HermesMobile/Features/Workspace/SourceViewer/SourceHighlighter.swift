import Highlightr
import UIKit

/// One syntax colour run inside a row's text, in UTF-16 units of the row content.
struct SourceHighlightRun: Equatable {
    let range: NSRange
    let color: UIColor
}

/// Which Highlightr grammar, if any, a workspace file gets.
enum SourceHighlightLanguage {
    /// Extensions Markdown fences never use, mapped onto grammar names.
    private static let extensionAliases: [String: String] = [
        "bash": "bash",
        "cc": "cpp",
        "cjs": "javascript",
        "cxx": "cpp",
        "h": "c",
        "hpp": "cpp",
        "mjs": "javascript",
        "plist": "xml"
    ]

    /// The chat renderer's Highlightr list plus Swift, which it routes to Splash instead.
    static let supported: Set<String> = MarkdownHighlightPolicy.highlightrLanguages.union(["swift"])

    /// The server's `language` wins when Highlightr knows it; the path extension is the fallback.
    static func resolve(path: String, serverLanguage: String?) -> String? {
        let candidates = [serverLanguage, (path as NSString).pathExtension].compactMap { $0 }
        for candidate in candidates {
            let lowered = candidate.lowercased()
            let normalized = extensionAliases[lowered] ?? MarkdownHighlightPolicy.normalizedLanguage(from: lowered)
            if let normalized, supported.contains(normalized) { return normalized }
        }
        return nil
    }
}

/// Runs Highlightr off the main actor. One request colours a contiguous slice of
/// lines; the caller keeps the runs per row and asks only for rows on screen.
actor SourceHighlighter {
    static let shared = SourceHighlighter()
    /// Lines longer than this are blanked before tokenizing; they draw plain.
    static let maxLineLength = 1_000

    private var highlightrsByAppearance: [Bool: Highlightr] = [:]

    /// Colour runs per line, or nil when Highlightr is unavailable, rejects the
    /// language, or hands back text that no longer matches the input.
    func highlight(lines: [String], language: String, isDark: Bool) -> [[SourceHighlightRun]]? {
        guard let highlightr = highlightr(isDark: isDark) else { return nil }
        let source = lines.map { $0.count > Self.maxLineLength ? "" : $0 }
        let joined = source.joined(separator: "\n")
        guard let attributed = highlightr.highlight(joined, as: language, fastRender: true),
              attributed.string == joined else { return nil }
        return Self.runsByLine(in: attributed, lineCount: lines.count)
    }

    private func highlightr(isDark: Bool) -> Highlightr? {
        if let cached = highlightrsByAppearance[isDark] { return cached }
        guard let highlightr = Highlightr() else { return nil }
        highlightr.setTheme(to: isDark ? "github-dark" : "xcode")
        highlightrsByAppearance[isDark] = highlightr
        return highlightr
    }

    /// Splits whole-string foreground colour runs into per-line runs with line-local
    /// offsets. Text Highlightr left uncoloured has no run and draws in the label colour.
    static func runsByLine(in attributed: NSAttributedString, lineCount: Int) -> [[SourceHighlightRun]] {
        var runs = Array(repeating: [SourceHighlightRun](), count: lineCount)
        let string = attributed.string as NSString
        var colorRuns: [(range: NSRange, color: UIColor)] = []
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let color = value as? UIColor { colorRuns.append((range, color)) }
        }

        var lineStart = 0
        var runCursor = 0
        for lineIndex in 0..<lineCount {
            guard lineStart <= string.length else { break }
            let remaining = NSRange(location: lineStart, length: string.length - lineStart)
            let newline = string.range(of: "\n", options: [], range: remaining)
            let lineEnd = newline.location == NSNotFound ? string.length : newline.location
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)

            while runCursor < colorRuns.count, NSMaxRange(colorRuns[runCursor].range) <= lineStart {
                runCursor += 1
            }
            var index = runCursor
            while index < colorRuns.count, colorRuns[index].range.location < lineEnd {
                let overlap = NSIntersectionRange(colorRuns[index].range, lineRange)
                if overlap.length > 0 {
                    runs[lineIndex].append(
                        SourceHighlightRun(
                            range: NSRange(location: overlap.location - lineStart, length: overlap.length),
                            color: colorRuns[index].color
                        )
                    )
                }
                index += 1
            }
            guard newline.location != NSNotFound else { break }
            lineStart = lineEnd + 1
        }
        return runs
    }
}
