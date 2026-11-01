import Foundation

struct MarkdownMathFormatter {
    static func replacingInlineMath(in markdown: String) -> String {
        replacingInlineMath(in: markdown) { renderedText(for: $0) }
    }

    /// Image destinations carry only expression source; font and appearance belong
    /// to the view, so streaming and settled segmentation produce identical output.
    static func inlineMathImages(in markdown: String) -> String {
        replacingInlineMath(in: markdown) { latex in
            guard latex.utf8.count <= 512 else { return nil }
            let encoded = Data(latex.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            // A nonempty alt keeps Foundation from dropping an image inside a link.
            return "![\u{FFFC}](hermex-math:///" + encoded + ")"
        }
    }

    private static func replacingInlineMath(in markdown: String, render: (String) -> String?) -> String {
        // Neither supported opener ($ or \() can occur without these ASCII bytes.
        guard markdown.utf8.contains(0x24) || markdown.utf8.contains(0x5C) else { return markdown }
        let characters = Array(markdown)
        guard characters.count >= 3 else { return markdown }

        let protected = MarkdownMathProtection.mask(for: characters)
        var result = ""
        var index = 0

        while index < characters.count {
            guard let delimiter = inlineDelimiter(in: characters, at: index, protected: protected),
                  let closeIndex = closingInlineDelimiter(
                    in: characters,
                    from: index + delimiter.openLength,
                    protected: protected,
                    delimiter: delimiter
                  )
            else {
                result.append(characters[index])
                index += 1
                continue
            }

            let latex = String(characters[(index + delimiter.openLength)..<closeIndex])
            if looksLikeMath(latex) {
                result += render(latex) ?? String(characters[index..<(closeIndex + delimiter.closeLength)])
                index = closeIndex + delimiter.closeLength
            } else {
                result.append(characters[index])
                index += 1
            }
        }

        return result
    }

    static func renderedText(for latex: String) -> String {
        let normalized = latex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\("#, with: "")
            .replacingOccurrences(of: #"\)"#, with: "")
            .replacingOccurrences(of: #"\["#, with: "")
            .replacingOccurrences(of: #"\]"#, with: "")

        var rendered = normalized
        rendered = replacingAligned(in: rendered)
        rendered = replacingCases(in: rendered)
        rendered = replacingMatrices(in: rendered)
        rendered = replacingStructuralCommands(in: rendered)
        rendered = replacingFractions(in: rendered)
        rendered = replacingSquareRoots(in: rendered)
        rendered = replacingTextCommands(in: rendered)
        rendered = replacingAccentCommands(in: rendered)
        rendered = replacingKnownCommands(in: rendered)
        rendered = replacingScripts(in: rendered)
        rendered = replacingEscapedSpacing(in: rendered)
        rendered = rendered
            .replacingOccurrences(of: #"\\"#, with: "\n")
            .replacingOccurrences(of: #"\,"#, with: " ")
            .replacingOccurrences(of: #"\;"#, with: " ")
            .replacingOccurrences(of: #"\ "#, with: " ")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")

        return normalizedWhitespace(in: rendered)
    }

    static func group(
        in characters: [Character],
        from startIndex: Int
    ) -> (value: String, endIndex: Int)? {
        guard startIndex < characters.count, characters[startIndex] == "{" else { return nil }

        var depth = 0
        var index = startIndex
        while index < characters.count {
            if characters[index] == "{", !MarkdownMathProtection.isEscaped(characters, at: index) {
                depth += 1
            } else if characters[index] == "}", !MarkdownMathProtection.isEscaped(characters, at: index) {
                depth -= 1
                if depth == 0 {
                    return (String(characters[(startIndex + 1)..<index]), index + 1)
                }
            }
            index += 1
        }

        return nil
    }

    static func isSimpleMathText(_ value: String) -> Bool {
        value.range(of: #"\s|[+\-*/=<>|·]"#, options: .regularExpression) == nil
    }

    static func matches(_ command: String, in characters: [Character], at index: Int) -> Bool {
        let commandCharacters = Array(command)
        guard index + commandCharacters.count <= characters.count else { return false }
        return Array(characters[index..<(index + commandCharacters.count)]) == commandCharacters
    }

    static func normalizedWhitespace(in value: String) -> String {
        value
            .components(separatedBy: "\n")
            .map { line in
                line
                    .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"∂\s+"#, with: "∂", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func skipSpaces(in characters: [Character], from startIndex: Int) -> Int {
        var index = startIndex
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        return index
    }

    private static func closingInlineDelimiter(
        in characters: [Character],
        from startIndex: Int,
        protected: [Bool],
        delimiter: InlineDelimiter
    ) -> Int? {
        var index = startIndex
        while index < characters.count {
            if characters[index] == "\n" {
                return nil
            }

            if delimiter.isClose(in: characters, at: index, protected: protected) {
                return index
            }

            // A live `$` that cannot close ends the candidate, as hermes-webui's `[^$]`
            // span does; scanning past it would pair with a later `$` and swallow prose.
            if delimiter == .dollar, characters[index] == "$", !protected[index],
               !MarkdownMathProtection.isEscaped(characters, at: index) {
                return nil
            }

            index += 1
        }
        return nil
    }

    private static func inlineDelimiter(
        in characters: [Character],
        at index: Int,
        protected: [Bool]
    ) -> InlineDelimiter? {
        for delimiter in InlineDelimiter.allCases where delimiter.isOpen(in: characters, at: index, protected: protected) {
            return delimiter
        }
        return nil
    }

    private static func looksLikeMath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"^[A-Za-z](?:_[A-Za-z0-9]+|\^[A-Za-z0-9]+)?$"#, options: .regularExpression) != nil {
            return true
        }
        if looksLikeAssignment(trimmed) { return true }
        // Bare numeric tuples are mathematical; bare prices and ordinary prose are not.
        if trimmed.first == "(", trimmed.last == ")",
           trimmed.range(of: #"^\(\s*[+-]?\d+(?:\.\d+)?(?:\s*,\s*[+-]?\d+(?:\.\d+)?)+\s*\)$"#,
                         options: .regularExpression) != nil { return true }
        if trimmed.contains("\\") || trimmed.contains("^") || trimmed.contains("_") { return true }
        return trimmed.range(of: #"[A-Za-z0-9]\s*[=<>+\-*/|]\s*[A-Za-z0-9]"#, options: .regularExpression) != nil
    }

    /// Recognizes assignment forms whose grouped right-hand side prevented the
    /// general operator rule from seeing an alphanumeric value after `=`.
    private static func looksLikeAssignment(_ value: String) -> Bool {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }

        let lhs = parts[0].trimmingCharacters(in: .whitespaces)
        guard lhs.range(
            of: #"^[A-Za-z](?:_[A-Za-z0-9]+|\^[A-Za-z0-9]+)?$"#,
            options: .regularExpression
        ) != nil else {
            return false
        }

        let rhs = parts[1].trimmingCharacters(in: .whitespaces)
        guard !rhs.isEmpty else { return false }

        let allowedSymbols = CharacterSet(charactersIn: #"\_^,+-*/.=<>|[](){}"#)
            .union(.alphanumerics)
            .union(.whitespaces)
        guard rhs.unicodeScalars.allSatisfy(allowedSymbols.contains) else { return false }

        var stack: [Character] = []
        let closingForOpening: [Character: Character] = ["[": "]", "(": ")", "{": "}"]
        let openingsForClosing: [Character: Character] = ["]": "[", ")": "(", "}": "{"]

        for character in rhs {
            if closingForOpening[character] != nil {
                stack.append(character)
            } else if let opening = openingsForClosing[character] {
                guard stack.popLast() == opening else { return false }
            }
        }

        guard stack.isEmpty else { return false }
        return rhs.range(of: #"[0-9\\_^,+\-*/<>|]"#, options: .regularExpression) != nil
    }
}

private enum InlineDelimiter: CaseIterable {
    case dollar
    case parens

    var openLength: Int {
        switch self {
        case .dollar:
            return 1
        case .parens:
            return 2
        }
    }

    var closeLength: Int {
        switch self {
        case .dollar:
            return 1
        case .parens:
            return 2
        }
    }

    func isOpen(in characters: [Character], at index: Int, protected: [Bool]) -> Bool {
        switch self {
        case .dollar:
            guard matches("$", in: characters, at: index, protected: protected) else { return false }
            if index > 0, characters[index - 1] == "$" { return false }
            if index + 1 < characters.count, characters[index + 1] == "$" { return false }
            // `$` followed by a digit or whitespace is currency or prose, not math:
            // mirrors hermes-webui's inline-math boundary guard, so amounts like
            // "$250" or "$5 and $10" never open a span that swallows the text
            // between them and the next `$` on the line.
            if index + 1 < characters.count, characters[index + 1].isNumber || characters[index + 1].isWhitespace { return false }
            return !MarkdownMathProtection.isEscaped(characters, at: index)
        case .parens:
            return matches(#"\("#, in: characters, at: index, protected: protected)
                && !MarkdownMathProtection.isEscaped(characters, at: index)
        }
    }

    func isClose(in characters: [Character], at index: Int, protected: [Bool]) -> Bool {
        switch self {
        case .dollar:
            guard matches("$", in: characters, at: index, protected: protected) else { return false }
            if index > 0, characters[index - 1] == "$" { return false }
            if index + 1 < characters.count, characters[index + 1] == "$" { return false }
            // Whitespace directly before a `$` reads as a prose boundary, not math:
            // matches hermes-webui, KaTeX auto-render, and markdown-it-katex.
            if index > 0, characters[index - 1].isWhitespace { return false }
            return !MarkdownMathProtection.isEscaped(characters, at: index)
        case .parens:
            return matches(#"\)"#, in: characters, at: index, protected: protected)
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
