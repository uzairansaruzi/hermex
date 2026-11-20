import Foundation

enum ModelDisplayNames {
    struct Parts: Equatable {
        let name: String
        let tag: String
    }

    private static let variantTags: [(suffix: String, label: String)] = [
        ("-fast", "Fast"),
        ("-flash", "Flash"),
        ("-thinking", "Thinking"),
        ("-preview", "Preview"),
        ("-latest", "Latest")
    ]

    private static let quantRegex = regex(#"-(UD-Q\d(?:_[A-Z0-9]+)*|Q\d(?:_[A-Z0-9]+)*|IQ\d(?:_[A-Z0-9]+)*|F16|BF16)$"#, caseInsensitive: true)
    private static let instructChatRegex = regex(#"-(?:Instruct|Chat)(?:-\d{4})?$"#, caseInsensitive: true)
    private static let contextWindowRegex = regex(#"\[(\d+[mk])\]$"#, caseInsensitive: true)
    private static let datePinRegex = regex(#"-\d{8}$"#)
    private static let claudeVersionRegex = regex(#"(\d)-(?=\d)"#)
    private static let parameterCountRegex = regex(#"\b(a?)(\d+(?:\.\d+)?)b\b"#, caseInsensitive: true)
    private static let vendorCasingRegex = regex(#"\b(Deepseek|Glm|Minimax|Openai|Ernie|Mimo|Bge|Vl|It|Fp8|Ai)\b"#)

    private static let vendorCasing: [String: String] = [
        "Deepseek": "DeepSeek",
        "Glm": "GLM",
        "Minimax": "MiniMax",
        "Openai": "OpenAI",
        "Ernie": "ERNIE",
        "Mimo": "MiMo",
        "Bge": "BGE",
        "Vl": "VL",
        "It": "IT",
        "Fp8": "FP8",
        "Ai": "AI"
    ]

    static func displayLabel(for modelID: String) -> String {
        let parts = parts(for: modelID)
        return parts.tag.isEmpty ? parts.name : "\(parts.name) · \(parts.tag)"
    }

    static func displayLabel(for modelID: String, displayName: String) -> String {
        let parts = parts(for: modelID, displayName: displayName)
        return parts.tag.isEmpty ? parts.name : "\(parts.name) · \(parts.tag)"
    }

    static func parts(for modelID: String, displayName: String) -> Parts {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != trimmedID else {
            return parts(for: modelID)
        }
        return Parts(name: displayName, tag: "")
    }

    static func parts(for modelID: String) -> Parts {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)

        var base = modelBaseID(trimmed)
        var colonTag = ""
        if let colon = base.lastIndex(of: ":"), colon != base.startIndex {
            colonTag = applyVendorCasing(titleCase(String(base[base.index(after: colon)...])))
            base = String(base[..<colon])
        }

        let split = splitTrailingTags(from: base)
        base = split.base
        var tags = [split.variant, split.quant].filter { !$0.isEmpty }

        if let contextWindow = firstMatch(contextWindowRegex, in: base) {
            tags.append(capture(contextWindow, 1, in: base).uppercased())
            base = before(contextWindow, in: base)
        }

        base = replacingMatches(datePinRegex, in: base) { _ in "" }

        if !colonTag.isEmpty { tags.append(colonTag) }

        let name = prettifyBase(base)
        return Parts(name: name.isEmpty ? trimmed : name, tag: tags.joined(separator: " "))
    }

    private static func modelBaseID(_ modelID: String) -> String {
        guard let slash = modelID.lastIndex(of: "/") else { return modelID }
        return String(modelID[modelID.index(after: slash)...])
    }

    private static func splitTrailingTags(from base: String) -> (base: String, variant: String, quant: String) {
        var base = base
        var variant = ""
        var quant = ""

        var progressed = true
        while progressed {
            progressed = false

            if variant.isEmpty, let tag = variantTags.first(where: { hasCaseInsensitiveSuffix(base, $0.suffix) }) {
                variant = tag.label
                base = String(base.dropLast(tag.suffix.count))
                progressed = true
            }

            if quant.isEmpty, let match = firstMatch(quantRegex, in: base) {
                quant = capture(match, 1, in: base).uppercased()
                base = before(match, in: base)
                if let marker = firstMatch(instructChatRegex, in: base) {
                    base = before(marker, in: base)
                }
                progressed = true
            }
        }

        return (base, variant, quant)
    }

    private static func prettifyBase(_ base: String) -> String {
        let lowercasedBase = base.lowercased()

        if lowercasedBase.hasPrefix("claude-") {
            let body = String(base.dropFirst("claude-".count))
            let dotted = claudeVersionRegex.stringByReplacingMatches(
                in: body, range: fullRange(body), withTemplate: "$1.")
            return applyVendorCasing(titleCase(dotted.replacingOccurrences(of: "-", with: " ")))
        }

        if lowercasedBase.hasPrefix("gpt-") {
            return "GPT-" + String(base.dropFirst("gpt-".count))
        }

        if lowercasedBase.hasPrefix("gemini-") {
            let body = "Gemini " + String(base.dropFirst("gemini-".count))
            return applyVendorCasing(titleCase(body.replacingOccurrences(of: "-", with: " ")))
        }

        return applyVendorCasing(titleCase(base.replacingOccurrences(of: "-", with: " ")))
    }

    private static func titleCase(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var previousIsWordCharacter = false
        for character in text {
            let isWordCharacter = character.isModelIDWordCharacter
            if isWordCharacter && !previousIsWordCharacter {
                result.append(character.uppercased())
            } else {
                result.append(character)
            }
            previousIsWordCharacter = isWordCharacter
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func applyVendorCasing(_ text: String) -> String {
        var cased = replacingMatches(parameterCountRegex, in: text) { match in
            capture(match, 1, in: text).uppercased() + capture(match, 2, in: text) + "B"
        }

        cased = replacingMatches(vendorCasingRegex, in: cased) { match in
            vendorCasing[capture(match, 1, in: cased)] ?? capture(match, 1, in: cased)
        }

        return cased
    }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func fullRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: fullRange(text))
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        guard let range = Range(match.range(at: index), in: text) else { return "" }
        return String(text[range])
    }

    private static func before(_ match: NSTextCheckingResult, in text: String) -> String {
        guard let prefixRange = Range(NSRange(location: 0, length: match.range.location), in: text) else {
            return text
        }
        return String(text[prefixRange])
    }

    private static func replacingMatches(
        _ regex: NSRegularExpression,
        in text: String,
        transform: (NSTextCheckingResult) -> String
    ) -> String {
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        regex.enumerateMatches(in: text, range: fullRange(text)) { match, _, _ in
            guard let match else { return }
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(match)
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }
        return result
    }

    private static func hasCaseInsensitiveSuffix(_ text: String, _ suffix: String) -> Bool {
        guard suffix.count <= text.count else { return false }
        return text.suffix(suffix.count).lowercased() == suffix.lowercased()
    }
}

private extension Character {
    var isModelIDWordCharacter: Bool {
        isLetter || isNumber || self == "_"
    }
}
