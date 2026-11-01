import Foundation

/// Reduces a reasoning block to the one-line preview its collapsed log row
/// shows: `summary(for:)` for a settled block, `latestThought(in:)` while it
/// streams. Pure so the selection and cut rules are unit-testable.
enum ReasoningSummaryFormatter {
    static let characterLimit = 80
    /// Newlines never count toward the limit, so a hard cap on characters read
    /// keeps a newline-heavy block from being rescanned in full on every chunk.
    static let scanLimit = characterLimit * 4
    /// How much of a live stream's end `latestThought(in:)` reads.
    static let tailLimit = 2_000

    /// The settled preview: the block's beginning with common markdown stripped,
    /// newline runs collapsed and cut with an ellipsis. Reads at most
    /// `scanLimit` characters.
    static func summary(for text: String) -> String {
        oneLine(stripMarkup(text.prefix(scanLimit)))
    }

    /// The live preview: the newest completed `**heading**` line, else the first
    /// sentence of the newest paragraph, stripped and cut like `summary(for:)`.
    /// Reads only the last `tailLimit` characters, so a long stream costs the
    /// same on every chunk.
    static func latestThought(in text: String) -> String {
        let lines = completeTail(of: text)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        if let heading = lines.reversed().lazy.compactMap(boldHeading).first {
            return oneLine(stripInlineMarkup(heading))
        }

        var paragraph: [Substring] = []
        for line in lines.reversed() {
            if line.allSatisfy(\.isWhitespace) {
                if paragraph.isEmpty { continue }
                break
            }
            paragraph.insert(line, at: 0)
        }
        let stripped = stripMarkup(Substring(paragraph.joined(separator: "\n"))).drop(while: \.isWhitespace)
        return oneLine(stripped[..<(sentenceEnd(in: stripped) ?? stripped.endIndex)])
    }

    /// The last `tailLimit` characters. When that cuts a line, the cut-off
    /// leading line (or sentence, for one long line) is dropped if anything
    /// follows it, so a fragment never reads as a whole paragraph.
    private static func completeTail(of text: String) -> Substring {
        let tail = text.suffix(tailLimit)
        guard tail.startIndex > text.startIndex,
              !text[text.index(before: tail.startIndex)].isNewline else { return tail }

        let restart = [tail.firstIndex(where: \.isNewline), sentenceEnd(in: tail)]
            .compactMap { $0 }
            .first { tail[$0...].contains { !$0.isWhitespace } }
        return restart.map { tail[$0...] } ?? tail
    }

    /// The text of a line that opens with a closed `**…**` span, which may be
    /// followed by more text.
    private static func boldHeading(_ line: Substring) -> Substring? {
        let trimmed = line.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix("**") else { return nil }
        let content = trimmed.dropFirst(2)
        guard let close = content.range(of: "**"), close.lowerBound > content.startIndex else { return nil }
        return content[..<close.lowerBound]
    }

    /// The index just past the first sentence terminator. `. ! ?` end a sentence
    /// only before whitespace or the end, so `v1.2` and `a.b` stay whole.
    private static func sentenceEnd(in text: Substring) -> Substring.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            switch text[index] {
            case "。", "！", "？":
                return next
            case ".", "!", "?":
                if next == text.endIndex || text[next].isWhitespace { return next }
            default:
                break
            }
            index = next
        }
        return nil
    }

    /// Drops each line's leading quote, heading and list markers, then its
    /// inline markup.
    private static func stripMarkup(_ text: Substring) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { stripInlineMarkup(stripLeadingMarkers($0)) }
            .joined(separator: "\n")
    }

    private static func stripLeadingMarkers(_ line: Substring) -> Substring {
        var rest = line.drop(while: \.isWhitespace)
        if rest.hasPrefix("> ") { rest = rest.dropFirst(2) }

        let hashes = rest.prefix(while: { $0 == "#" })
        if !hashes.isEmpty, rest.dropFirst(hashes.count).first == " " {
            return rest.dropFirst(hashes.count + 1)
        }
        if ["- ", "* ", "+ "].contains(where: { rest.hasPrefix($0) }) {
            return rest.dropFirst(2)
        }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        let afterDigits = rest.dropFirst(digits.count)
        if !digits.isEmpty, afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") {
            return afterDigits.dropFirst(2)
        }
        return rest
    }

    /// Removes backticks and `*` emphasis runs, and reduces `[label](url)` to
    /// its label. A code span's text is kept as written, a `*` between spaces
    /// (`2 * 3`) or within an ASCII word (`2*3`) stays, and underscores are never
    /// touched, so identifiers like `retry_policy` survive.
    private static func stripInlineMarkup(_ line: Substring) -> String {
        let characters = Array(line)
        var result = ""
        var linkTargetSkip: (from: Int, to: Int)?
        var index = 0

        while index < characters.count {
            if let skip = linkTargetSkip, index == skip.from {
                index = skip.to
                linkTargetSkip = nil
                continue
            }

            switch characters[index] {
            case "`":
                let runEnd = characters[index...].firstIndex { $0 != "`" } ?? characters.count
                let runLength = runEnd - index
                let spanLimit = linkTargetSkip?.from ?? characters.count
                if let close = closingBackticks(in: characters, from: runEnd, length: runLength, limit: spanLimit) {
                    result.append(contentsOf: characters[runEnd..<close])
                    index = close + runLength
                } else {
                    index = runEnd
                }
            case "*":
                let runEnd = characters[index...].firstIndex { $0 != "*" } ?? characters.count
                let before = index > 0 ? characters[index - 1] : nil
                let after = runEnd < characters.count ? characters[runEnd] : nil
                let isASCIIWord = { (character: Character?) in
                    character.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
                }
                let literal = before?.isWhitespace == true && after?.isWhitespace == true
                    || isASCIIWord(before) && isASCIIWord(after)
                if literal { result.append(contentsOf: characters[index..<runEnd]) }
                index = runEnd
            case "[":
                if linkTargetSkip == nil,
                   let labelEnd = characters[(index + 1)...].firstIndex(of: "]"),
                   labelEnd + 1 < characters.count, characters[labelEnd + 1] == "(",
                   let targetEnd = closingParenthesis(in: characters, from: labelEnd + 2) {
                    linkTargetSkip = (labelEnd, targetEnd + 1)
                } else {
                    result.append("[")
                }
                index += 1
            default:
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    /// The start of the next backtick run of exactly `length` before `limit`,
    /// which closes a code span the way CommonMark pairs them (``a `b` c``).
    private static func closingBackticks(
        in characters: [Character], from start: Int, length: Int, limit: Int
    ) -> Int? {
        var index = start
        while index < limit {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            let runEnd = characters[index..<limit].firstIndex { $0 != "`" } ?? limit
            if runEnd - index == length { return index }
            index = runEnd
        }
        return nil
    }

    /// The `)` closing a link target that starts at `start`, past any balanced
    /// pairs inside it, as in `https://example.com/a_(b)`.
    private static func closingParenthesis(in characters: [Character], from start: Int) -> Int? {
        var depth = 0
        for index in start..<characters.count {
            switch characters[index] {
            case "(":
                depth += 1
            case ")":
                if depth == 0 { return index }
                depth -= 1
            default:
                break
            }
        }
        return nil
    }

    /// Newline runs collapse to a single space and anything past the limit is
    /// cut with an ellipsis.
    private static func oneLine(_ text: some StringProtocol) -> String {
        var result = ""
        var count = 0
        var pendingSpace = false

        for character in text {
            if character.isNewline {
                pendingSpace = !result.isEmpty
                continue
            }

            if pendingSpace {
                result.append(" ")
                count += 1
                pendingSpace = false
            }

            result.append(character)
            count += 1

            if count > characterLimit {
                return String(result.prefix(characterLimit)) + "..."
            }
        }

        return result.trimmingCharacters(in: .whitespaces)
    }
}
