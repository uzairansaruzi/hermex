import Foundation

/// Reduces a reasoning block to the one-line preview its collapsed log row
/// shows. Pure so the cut rules are unit-testable.
enum ReasoningSummaryFormatter {
    static let characterLimit = 80
    /// Newlines never count toward the limit, so a hard cap on characters read
    /// keeps a newline-heavy block from being rescanned in full on every chunk.
    static let scanLimit = characterLimit * 4

    /// Newline runs collapse to a single space and anything past the limit is
    /// cut with an ellipsis. Reads at most `scanLimit` characters so summarising
    /// a long live stream on every chunk stays cheap.
    static func summary(for text: String) -> String {
        var result = ""
        var count = 0
        var pendingSpace = false

        for character in text.prefix(scanLimit) {
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
