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

    /// The excerpt with every occurrence of the query bolded.
    ///
    /// Matching is case-insensitive and runs over `String` ranges, so composed
    /// and decomposed spellings of the same characters match each other and the
    /// bolded range is the text's own, not the query's length. Diacritics are
    /// *not* folded: the server matched the query literally, so folding them
    /// here would bold a span the server never treated as the hit. When
    /// redaction has replaced the match, nothing is bolded and the plain
    /// excerpt still shows.
    var highlighted: AttributedString {
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
