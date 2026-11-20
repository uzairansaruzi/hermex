import Highlightr
import UIKit

struct SourceHighlightRun: Equatable {
    let range: NSRange
    let color: UIColor
}

enum SourceHighlightLanguage {
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

    static let supported: Set<String> = MarkdownHighlightPolicy.highlightrLanguages.union(["swift"])

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

actor SourceHighlighter {
    static let shared = SourceHighlighter()
    static let maxLineLength = 1_000

    private var highlightrsByAppearance: [Bool: Highlightr] = [:]

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
