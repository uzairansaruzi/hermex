import Foundation

struct SessionSearchExcerpt: Equatable {
    let text: String
    let query: String
    private let marked: AttributedString?

    init(text: String, query: String) {
        self.text = Self.displayText(text)
        self.query = query
        marked = nil
    }

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
            isMatch = mark == open
            hasMarks = true
            rest = rest[mark.upperBound...]
        }
        self.text = text
        self.query = query
        self.marked = hasMarks ? marked : nil
    }

    private static func displayText(_ raw: String) -> String {
        var text = raw
        for escape in ["\\r\\n", "\\n", "\\r", "\\t"] {
            text = text.replacingOccurrences(of: escape, with: " ")
        }

        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

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
