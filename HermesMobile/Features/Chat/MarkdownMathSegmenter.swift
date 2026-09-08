import Foundation

enum MarkdownMathSegment: Equatable {
    case markdown(String)
    case displayMath(String)
}

/// The rendering shape of a piece of markdown, decided once.
///
/// `plain` is the overwhelmingly common case (an answer with no display math).
/// Its payload has **already** been through
/// `MarkdownMathFormatter.replacingInlineMath(in:)`, so callers must not run
/// that pass again — doing so scans the whole string a second time for no
/// change in output.
enum MarkdownMathLayout: Equatable {
    case plain(String)
    case segmented([MarkdownMathSegment])
}

struct MarkdownMathSegmenter {
    static func segments(in content: String) -> [MarkdownMathSegment] {
        // Skip Markdown protection and delimiter scans when no math opener is possible.
        guard content.utf8.contains(0x24) || content.utf8.contains(0x5C) else {
            return [.markdown(content)]
        }
        let characters = Array(content)
        guard characters.count >= 4 else {
            return [.markdown(MarkdownMathFormatter.replacingInlineMath(in: content))]
        }

        let protected = MarkdownMathProtection.mask(for: characters)
        var segments: [MarkdownMathSegment] = []
        var cursor = 0
        var index = 0

        while index < characters.count {
            guard let delimiter = displayDelimiter(in: characters, at: index, protected: protected),
                  let closeIndex = closingDisplayDelimiter(
                    in: characters,
                    from: index + delimiter.openLength,
                    protected: protected,
                    delimiter: delimiter
                  )
            else {
                index += 1
                continue
            }

            appendMarkdown(String(characters[cursor..<index]), to: &segments)
            let latex = String(characters[(index + delimiter.openLength)..<closeIndex])
            appendDisplayMath(latex, to: &segments)
            index = closeIndex + delimiter.closeLength
            cursor = index
        }

        appendMarkdown(String(characters[cursor...]), to: &segments)
        return segments.isEmpty ? [.markdown(MarkdownMathFormatter.replacingInlineMath(in: content))] : segments
    }

    private static func closingDisplayDelimiter(
        in characters: [Character],
        from startIndex: Int,
        protected: [Bool],
        delimiter: DisplayDelimiter
    ) -> Int? {
        var index = startIndex
        while index < characters.count {
            if delimiter.isClose(in: characters, at: index, protected: protected) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func displayDelimiter(
        in characters: [Character],
        at index: Int,
        protected: [Bool]
    ) -> DisplayDelimiter? {
        for delimiter in DisplayDelimiter.allCases where delimiter.isOpen(in: characters, at: index, protected: protected) {
            return delimiter
        }
        return nil
    }

    private static func appendMarkdown(
        _ markdown: String,
        to segments: inout [MarkdownMathSegment]
    ) {
        let rendered = MarkdownMathFormatter.replacingInlineMath(in: markdown)
        guard !rendered.isEmpty else { return }
        segments.append(.markdown(rendered))
    }

    private static func appendDisplayMath(
        _ latex: String,
        to segments: inout [MarkdownMathSegment]
    ) {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(.displayMath(trimmed))
    }
}

private enum DisplayDelimiter: CaseIterable {
    case dollars
    case brackets

    var openLength: Int {
        switch self {
        case .dollars, .brackets:
            return 2
        }
    }

    var closeLength: Int {
        switch self {
        case .dollars, .brackets:
            return 2
        }
    }

    func isOpen(in characters: [Character], at index: Int, protected: [Bool]) -> Bool {
        switch self {
        case .dollars:
            return matches("$$", in: characters, at: index, protected: protected)
                && !MarkdownMathProtection.isEscaped(characters, at: index)
        case .brackets:
            return matches(#"\["#, in: characters, at: index, protected: protected)
                && !MarkdownMathProtection.isEscaped(characters, at: index)
        }
    }

    func isClose(in characters: [Character], at index: Int, protected: [Bool]) -> Bool {
        switch self {
        case .dollars:
            return matches("$$", in: characters, at: index, protected: protected)
                && !MarkdownMathProtection.isEscaped(characters, at: index)
        case .brackets:
            return matches(#"\]"#, in: characters, at: index, protected: protected)
                && !MarkdownMathProtection.isEscaped(characters, at: index)
        }
    }

    private func matches(
        _ token: String,
        in characters: [Character],
        at index: Int,
        protected: [Bool]
    ) -> Bool {
        let tokenCharacters = Array(token)
        guard index >= 0, index + tokenCharacters.count <= characters.count else { return false }
        for offset in 0..<tokenCharacters.count where protected[index + offset] {
            return false
        }
        return Array(characters[index..<(index + tokenCharacters.count)]) == tokenCharacters
    }
}

enum MarkdownMathProtection {
    static func mask(for characters: [Character]) -> [Bool] {
        let fenced = fencedCodeMask(for: characters)
        let inline = inlineCodeMask(for: characters, existingMask: fenced)
        return zip(fenced, inline).map { $0 || $1 }
    }

    static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }

        var backslashCount = 0
        var cursor = index - 1
        while cursor >= 0, characters[cursor] == "\\" {
            backslashCount += 1
            if cursor == 0 { break }
            cursor -= 1
        }

        return backslashCount % 2 == 1
    }

    private static func fencedCodeMask(for characters: [Character]) -> [Bool] {
        var mask = Array(repeating: false, count: characters.count)
        var lineStart = 0
        var fenceStart: Int?
        var fenceCharacter: Character?

        while lineStart < characters.count {
            let lineEnd = nextLineEnd(in: characters, from: lineStart)
            let nextLineStart = lineEnd < characters.count ? lineEnd + 1 : lineEnd

            if let opening = fenceOpening(in: characters, lineStart: lineStart, lineEnd: lineEnd) {
                if let start = fenceStart, opening.character == fenceCharacter {
                    mark(&mask, start..<nextLineStart)
                    fenceStart = nil
                    fenceCharacter = nil
                } else if fenceStart == nil {
                    fenceStart = lineStart
                    fenceCharacter = opening.character
                }
            }

            lineStart = nextLineStart
        }

        if let start = fenceStart {
            mark(&mask, start..<characters.count)
        }

        return mask
    }

    private static func inlineCodeMask(for characters: [Character], existingMask: [Bool]) -> [Bool] {
        var mask = Array(repeating: false, count: characters.count)
        var index = 0

        while index < characters.count {
            guard characters[index] == "`", !existingMask[index] else {
                index += 1
                continue
            }

            let runLength = backtickRunLength(in: characters, at: index)
            if let closeIndex = closingBacktickRun(
                in: characters,
                from: index + runLength,
                length: runLength,
                existingMask: existingMask
            ) {
                mark(&mask, index..<(closeIndex + runLength))
                index = closeIndex + runLength
            } else {
                index += runLength
            }
        }

        return mask
    }

    private static func fenceOpening(
        in characters: [Character],
        lineStart: Int,
        lineEnd: Int
    ) -> (character: Character, count: Int)? {
        var cursor = lineStart
        while cursor < lineEnd, characters[cursor].isWhitespace {
            cursor += 1
        }

        guard cursor + 2 < lineEnd else { return nil }
        let candidate = characters[cursor]
        guard candidate == "`" || candidate == "~" else { return nil }

        var count = 0
        while cursor + count < lineEnd, characters[cursor + count] == candidate {
            count += 1
        }

        return count >= 3 ? (candidate, count) : nil
    }

    private static func closingBacktickRun(
        in characters: [Character],
        from startIndex: Int,
        length: Int,
        existingMask: [Bool]
    ) -> Int? {
        var index = startIndex
        while index < characters.count {
            if characters[index] == "`", !existingMask[index], backtickRunLength(in: characters, at: index) == length {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func backtickRunLength(in characters: [Character], at index: Int) -> Int {
        var count = 0
        while index + count < characters.count, characters[index + count] == "`" {
            count += 1
        }
        return count
    }

    private static func nextLineEnd(in characters: [Character], from startIndex: Int) -> Int {
        var index = startIndex
        while index < characters.count, characters[index] != "\n" {
            index += 1
        }
        return index
    }

    private static func mark(_ mask: inout [Bool], _ range: Range<Int>) {
        for index in range where mask.indices.contains(index) {
            mask[index] = true
        }
    }
}

extension [MarkdownMathSegment] {
    var containsMath: Bool {
        contains {
            if case .displayMath = $0 { return true }
            return false
        }
    }
}

/// Memoizes the math-segmentation pass, which is pure over its input string.
///
/// **Why this exists.** `segments(in:)` walks the whole string twice (once to
/// build the protection mask, once to scan) and the no-math branch then ran
/// `replacingInlineMath` over the whole string *again*. Measured on this repo's
/// sources with `-O`, an 8 KB assistant answer cost ~7.5 ms per call. SwiftUI
/// re-evaluates a body for reasons unrelated to the text — a sibling fold
/// toggling, a scroll-position flip, a `@AppStorage` write — so that cost was
/// paid repeatedly for a string that never changed. A cache hit is ~0.0001 ms.
///
/// Keyed by the exact content string; unchanged text is the whole point.
/// `NSCache` is used so the entries evict under memory pressure rather than
/// growing with transcript length, and it is thread-safe, which matters
/// because SwiftUI may evaluate bodies off the main thread.
enum MarkdownMathLayoutCache {
    /// Streaming content mutates on nearly every token, so caching it would
    /// only churn the cache. Bodies longer than this are still segmented, just
    /// not stored.
    static let maxCachedCharacterCount = 100_000

    private static let storage: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 240
        return cache
    }()

    private final class Box {
        let layout: MarkdownMathLayout
        init(_ layout: MarkdownMathLayout) { self.layout = layout }
    }

    static func layout(for content: String) -> MarkdownMathLayout {
        guard content.count <= maxCachedCharacterCount else {
            return computeLayout(for: content)
        }

        let key = content as NSString
        if let cached = storage.object(forKey: key) {
            return cached.layout
        }

        let layout = computeLayout(for: content)
        storage.setObject(Box(layout), forKey: key)
        return layout
    }

    /// Layout without reading or writing the cache.
    ///
    /// Streaming text changes on nearly every token, so caching it would insert
    /// a new entry per token and evict the settled answers the cache exists to
    /// protect. Callers on the streaming path still get the single-pass benefit
    /// (no redundant second `replacingInlineMath` walk) without the churn.
    static func uncachedLayout(for content: String) -> MarkdownMathLayout {
        computeLayout(for: content)
    }

    private static func computeLayout(for content: String) -> MarkdownMathLayout {
        let segments = MarkdownMathSegmenter.segments(in: content)
        guard segments.containsMath else {
            // Reuse the markdown the segmenter already produced. It has been
            // inline-math-formatted, so re-running that pass here would be a
            // second full-string walk for an identical result.
            //
            // One exception: the segmenter *recognises* a display-math span but
            // drops it when the body is empty or whitespace-only (`$$ $$`,
            // `\[ \]`). Those produce no `.displayMath` segment, so
            // `containsMath` is false, yet the surrounding markdown segments no
            // longer contain the delimiters — joining them would silently
            // swallow literal text the old single-pass renderer preserved.
            //
            // Checking the segment count is not enough: an empty span at the
            // very start still leaves exactly one markdown segment. Instead,
            // ask whether the content contains a display delimiter at all. If
            // it does and nothing was emitted as math, the segmenter consumed
            // delimiters that the legacy pass would have preserved, so defer to
            // the legacy whole-string pass.
            //
            // This costs an extra walk only for content carrying a display
            // delimiter that produced no math, which is rare. Content with no
            // display delimiters at all -- the overwhelmingly common case --
            // takes the fast path untouched.
            guard !containsDisplayDelimiter(content) else {
                return .plain(MarkdownMathFormatter.replacingInlineMath(in: content))
            }

            let joined = segments.compactMap { segment -> String? in
                guard case .markdown(let markdown) = segment else { return nil }
                return markdown
            }.joined()
            return .plain(joined)
        }
        return .segmented(segments)
    }

    /// Cheap scan for a display-math opener/closer (`$$` or `\[` / `\]`).
    ///
    /// Deliberately conservative: a false positive only costs one extra pass,
    /// while a false negative would drop literal text from the transcript.
    private static func containsDisplayDelimiter(_ content: String) -> Bool {
        content.contains("$$") || content.contains("\\[") || content.contains("\\]")
    }

    /// Test seam: drop memoized layouts so a test can observe a cold pass.
    static func removeAll() {
        storage.removeAllObjects()
    }

    /// Test seam: whether `content` currently has a memoized entry.
    ///
    /// Exists so a test can assert the *absence* of caching on the streaming
    /// path. Comparing two layout values cannot do that — they are equal
    /// whether or not the cache was written — so without this probe the
    /// non-pollution contract is untestable.
    static func hasCachedLayout(for content: String) -> Bool {
        storage.object(forKey: content as NSString) != nil
    }
}
