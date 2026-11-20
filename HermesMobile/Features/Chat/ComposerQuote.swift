import Foundation

struct ComposerQuote: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }

    var preview: String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > 72 else { return collapsed }
        return String(collapsed.prefix(71)) + "…"
    }
}

struct ComposerDraftContent: Equatable, Sendable {
    var text: String
    var quotes: [ComposerQuote]

    static let empty = ComposerDraftContent(text: "", quotes: [])

    var isEmpty: Bool {
        text.isEmpty && quotes.isEmpty
    }
}

enum ComposerQuoteMessageFormatter {
    static func message(text: String, quotes: [ComposerQuote]) -> String {
        let quotedPassages = quotes.map { quote in
            quote.text
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
        }

        return (quotedPassages + (text.isEmpty ? [] : [text]))
            .joined(separator: "\n\n")
    }
}
