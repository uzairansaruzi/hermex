import Foundation

extension MarkdownMathFormatter {
    static func replacingStructuralCommands(in value: String) -> String {
        var result = value
        for command in ["\\boxed"] {
            result = replacingCommandWithOneGroup(command, in: result) { body in
                renderedText(for: body)
            }
        }
        return result
    }

    static func replacingFractions(in value: String) -> String {
        replacingCommandWithTwoGroups("\\frac", in: value) { numerator, denominator in
            let top = renderedText(for: numerator)
            let bottom = renderedText(for: denominator)
            if isSimpleMathText(top), isSimpleMathText(bottom) {
                return "\(top)/\(bottom)"
            }
            return "(\(top))/(\(bottom))"
        }
    }

    static func replacingSquareRoots(in value: String) -> String {
        replacingCommandWithOneGroup("\\sqrt", in: value) { radicand in
            let rendered = renderedText(for: radicand)
            return isSimpleMathText(rendered) ? "√\(rendered)" : "√(\(rendered))"
        }
    }

    static func replacingTextCommands(in value: String) -> String {
        var result = value
        result = replacingCommandWithOneGroup("\\mathcal", in: result) { body in
            mathcalText(renderedText(for: body))
        }

        for command in ["\\mathbf", "\\mathrm", "\\operatorname", "\\text"] {
            result = replacingCommandWithOneGroup(command, in: result) { body in
                renderedText(for: body)
            }
        }
        return result
    }

    static func replacingAccentCommands(in value: String) -> String {
        replacingCommandWithOneGroup("\\hat", in: value) { body in
            hattedText(renderedText(for: body))
        }
    }

    // Fixed literal commands, longest first so prefix commands do not consume longer ones.
    private static let knownCommandReplacements: [(String, String)] = [
        (#"\left"#, ""),
        (#"\right"#, ""),
        (#"\bigl"#, ""),
        (#"\bigr"#, ""),
        (#"\Bigl"#, ""),
        (#"\Bigr"#, ""),
        (#"\big"#, ""),
        (#"\Big"#, ""),
        (#"\pm"#, "±"),
        (#"\mp"#, "∓"),
        (#"\times"#, "×"),
        (#"\cdot"#, "·"),
        (#"\div"#, "÷"),
        (#"\mid"#, "|"),
        (#"\lVert"#, "‖"),
        (#"\rVert"#, "‖"),
        (#"\Vert"#, "‖"),
        (#"\log"#, "log"),
        (#"\ln"#, "ln"),
        (#"\sin"#, "sin"),
        (#"\cos"#, "cos"),
        (#"\tan"#, "tan"),
        (#"\arg"#, "arg"),
        (#"\min"#, "min"),
        (#"\max"#, "max"),
        (#"\lim"#, "lim"),
        (#"\exp"#, "exp"),
        (#"\det"#, "det"),
        (#"\Rightarrow"#, "⇒"),
        (#"\rightarrow"#, "→"),
        (#"\leftarrow"#, "←"),
        (#"\Leftrightarrow"#, "⇔"),
        (#"\top"#, "⊤"),
        (#"\bot"#, "⊥"),
        (#"\to"#, "→"),
        (#"\leq"#, "≤"),
        (#"\le"#, "≤"),
        (#"\geq"#, "≥"),
        (#"\ge"#, "≥"),
        (#"\neq"#, "≠"),
        (#"\ne"#, "≠"),
        (#"\approx"#, "≈"),
        (#"\ldots"#, "…"),
        (#"\cdots"#, "⋯"),
        (#"\infty"#, "∞"),
        (#"\pi"#, "π"),
        (#"\theta"#, "θ"),
        (#"\alpha"#, "α"),
        (#"\beta"#, "β"),
        (#"\rho"#, "ρ"),
        (#"\varepsilon"#, "ε"),
        (#"\epsilon"#, "ε"),
        (#"\gamma"#, "γ"),
        (#"\delta"#, "δ"),
        (#"\lambda"#, "λ"),
        (#"\mu"#, "μ"),
        (#"\sigma"#, "σ"),
        (#"\nabla"#, "∇"),
        (#"\partial"#, "∂"),
        (#"\sum"#, "∑"),
        (#"\prod"#, "∏"),
        (#"\int"#, "∫")
    ].sorted { $0.0.count > $1.0.count }

    static func replacingKnownCommands(in value: String) -> String {
        var result = value
        for (pattern, replacement) in knownCommandReplacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .literal)
        }

        return result
    }

    static func replacingScripts(in value: String) -> String {
        let characters = Array(value)
        var result = ""
        var index = 0

        while index < characters.count {
            let marker = characters[index]
            guard marker == "^" || marker == "_" else {
                result.append(marker)
                index += 1
                continue
            }

            let bodyStart = index + 1
            let parsed: (String, Int)?
            if bodyStart < characters.count, characters[bodyStart] == "{" {
                parsed = group(in: characters, from: bodyStart)
            } else {
                parsed = unbracedScript(in: characters, from: bodyStart)
            }

            guard let parsed else {
                result.append(marker)
                index += 1
                continue
            }

            let rendered = renderedText(for: parsed.0)
            result += marker == "^" ? superscript(rendered) : subscriptText(rendered)
            index = parsed.1
        }

        return result
    }

    static func replacingEscapedSpacing(in value: String) -> String {
        value
            .replacingOccurrences(of: #"\\quad"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\\qquad"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\\!"#, with: "", options: .regularExpression)
    }

    private static func replacingCommandWithOneGroup(
        _ command: String,
        in value: String,
        transform: (String) -> String
    ) -> String {
        let characters = Array(value)
        var result = ""
        var index = 0

        while index < characters.count {
            guard matches(command, in: characters, at: index),
                  let first = group(in: characters, from: skipSpaces(in: characters, from: index + command.count))
            else {
                result.append(characters[index])
                index += 1
                continue
            }

            result += transform(first.value)
            index = first.endIndex
        }

        return result
    }

    private static func replacingCommandWithTwoGroups(
        _ command: String,
        in value: String,
        transform: (String, String) -> String
    ) -> String {
        let characters = Array(value)
        var result = ""
        var index = 0

        while index < characters.count {
            let firstStart = skipSpaces(in: characters, from: index + command.count)
            guard matches(command, in: characters, at: index),
                  let first = group(in: characters, from: firstStart),
                  let second = group(in: characters, from: skipSpaces(in: characters, from: first.endIndex))
            else {
                result.append(characters[index])
                index += 1
                continue
            }

            result += transform(first.value, second.value)
            index = second.endIndex
        }

        return result
    }

    private static func unbracedScript(
        in characters: [Character],
        from startIndex: Int
    ) -> (String, Int)? {
        guard startIndex < characters.count else { return nil }
        if characters[startIndex] == "\\" {
            var endIndex = startIndex + 1
            while endIndex < characters.count, characters[endIndex].isLetter {
                endIndex += 1
            }
            if endIndex == startIndex + 1, endIndex < characters.count {
                return (String(characters[endIndex]), endIndex + 1)
            }
            return (String(characters[startIndex..<endIndex]), endIndex)
        }
        return (String(characters[startIndex]), startIndex + 1)
    }

    private static func superscript(_ value: String) -> String {
        let mapped = mappedScript(value, using: superscriptCharacters)
        return mapped == value ? "^\(value)" : mapped
    }

    private static func subscriptText(_ value: String) -> String {
        mappedScript(value, using: subscriptCharacters)
    }

    private static func mappedScript(_ value: String, using map: [Character: Character]) -> String {
        String(value.map { map[$0] ?? $0 })
    }

    private static func hattedText(_ value: String) -> String {
        if value.count == 1, let character = value.first {
            return hattedCharacters[character].map(String.init) ?? "\(value)\u{0302}"
        }
        return "\(value)\u{0302}"
    }

    private static func mathcalText(_ value: String) -> String {
        String(value.map { mathcalCharacters[$0] ?? $0 })
    }

    private static let hattedCharacters: [Character: Character] = [
        "a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û",
        "A": "Â", "E": "Ê", "I": "Î", "O": "Ô", "U": "Û",
        "x": "x̂", "y": "ŷ", "z": "ẑ"
    ]

    private static let mathcalCharacters: [Character: Character] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ", "G": "𝒢", "H": "ℋ", "I": "ℐ",
        "J": "𝒥", "K": "𝒦", "L": "ℒ", "M": "ℳ", "N": "𝒩", "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ",
        "S": "𝒮", "T": "𝒯", "U": "𝒰", "V": "𝒱", "W": "𝒲", "X": "𝒳", "Y": "𝒴", "Z": "𝒵"
    ]

    private static let superscriptCharacters: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ",
        "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ"
    ]

    private static let subscriptCharacters: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]
}
