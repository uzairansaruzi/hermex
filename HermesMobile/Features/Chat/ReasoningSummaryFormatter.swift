import Foundation

enum ReasoningSummaryFormatter {
    static let characterLimit = 80
    static let scanLimit = characterLimit * 4
    static let tailLimit = 2_000

    static func summary(for text: String) -> String {
        oneLine(stripMarkup(text.prefix(scanLimit)))
    }

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

    private static func completeTail(of text: String) -> Substring {
        let tail = text.suffix(tailLimit)
        guard tail.startIndex > text.startIndex,
              !text[text.index(before: tail.startIndex)].isNewline else { return tail }

        let restart = [tail.firstIndex(where: \.isNewline), sentenceEnd(in: tail)]
            .compactMap { $0 }
            .first { tail[$0...].contains { !$0.isWhitespace } }
        return restart.map { tail[$0...] } ?? tail
    }

    private static func boldHeading(_ line: Substring) -> Substring? {
        let trimmed = line.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix("**") else { return nil }
        let content = trimmed.dropFirst(2)
        guard let close = content.range(of: "**"), close.lowerBound > content.startIndex else { return nil }
        return content[..<close.lowerBound]
    }

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
