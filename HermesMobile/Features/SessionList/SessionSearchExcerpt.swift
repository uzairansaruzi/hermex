import Foundation

/// One content-search excerpt to show under a session row, paired with the
/// query that produced it so the row can bold the matched ranges.
///
/// `text` is the server's `match_preview`: a redacted, whitespace-collapsed
/// window of the matched message, already elided with `...` on either side when
/// it was cut. Servers older than the upstream commit that added
/// `_session_search_preview` omit the field, so no excerpt is built at all.
struct SessionSearchExcerpt: Equatable {
    let text: String
    let query: String
    /// The excerpt with the host's own matches bolded, when it marked them (a Hermes snippet).
    private let marked: AttributedString?

    init(text: String, query: String) {
        self.text = Self.displayText(text)
        self.query = query
        marked = nil
    }

    /// A Hermes search snippet (#1053): the host's FTS `snippet()` text, with `>>>` before and
    /// `<<<` after each match. The marked spans are bolded and the marks never show, so
    /// `text`, which VoiceOver reads, is plain. A snippet without marks (the host's substring
    /// search, for scripts FTS can't split) bolds the query instead, as a webui excerpt does.
    init(hermesSnippet snippet: String, query: String) {
        var text = ""
        var marked = AttributedString()
        var isMatch = false
        var hasMarks = false
        var rest = Self.displayText(snippet)[...]
        while !rest.isEmpty {
            let open = rest.range(of: ">>>")
            let close = rest.range(of: "<<<")
            let mark = [open, close].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
            let piece = String(rest[..<(mark?.lowerBound ?? rest.endIndex)])
            text += piece
            var run = AttributedString(piece)
            if isMatch { run.inlinePresentationIntent = .stronglyEmphasized }
            marked += run
            guard let mark else { break }
            // A stray mark only ends or starts the bolding; it is never shown either.
            isMatch = mark == open
            hasMarks = true
            rest = rest[mark.upperBound...]
        }
        self.text = text
        self.query = query
        self.marked = hasMarks ? marked : nil
    }

    /// The server previews the raw stored message text, so an excerpt taken
    /// from a serialized tool result arrives carrying that JSON's escapes:
    /// `...0% /\n---\nRAM: 8.0 GB", "exit_code": 0,...`. Those two-character
    /// escapes become spaces and runs of whitespace collapse, so the one line
    /// reads instead of showing its own punctuation.
    ///
    /// A Windows path (`C:\new`) is the false positive this accepts. It is
    /// worth it for a truncated preview line that is never used as data, and
    /// the alternative — guessing whether the excerpt "is JSON" — misfires in
    /// both directions.
    private static func displayText(_ raw: String) -> String {
        var text = raw
        for escape in ["\\r\\n", "\\n", "\\r", "\\t"] {
            text = text.replacingOccurrences(of: escape, with: " ")
        }

        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The excerpt with every occurrence of the query bolded, or a Hermes snippet's marked matches.
    ///
    /// Matching is case-insensitive and runs over `String` ranges, so composed
    /// and decomposed spellings of the same characters match each other and the
    /// bolded range is the text's own, not the query's length. Diacritics are
    /// *not* folded: the server matched the query literally, so folding them
    /// here would bold a span the server never treated as the hit. When
    /// redaction has replaced the match, nothing is bolded and the plain
    /// excerpt still shows.
    var highlighted: AttributedString {
        if let marked { return marked }
        guard !query.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        var cursor = text.startIndex

        while cursor < text.endIndex,
              let match = text.range(of: query, options: .caseInsensitive, range: cursor..<text.endIndex),
              !match.isEmpty {
            if match.lowerBound > cursor {
                result += AttributedString(String(text[cursor..<match.lowerBound]))
            }

            var hit = AttributedString(String(text[match]))
            hit.inlinePresentationIntent = .stronglyEmphasized
            result += hit

            cursor = match.upperBound
        }

        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor...]))
        }

        return result
    }
}
