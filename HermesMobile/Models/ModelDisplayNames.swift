import Foundation

/// Display-only prettifier for raw model ids, ported from the Hermes desktop
/// app's `apps/desktop/src/lib/model-status-label.ts`. The gateway's
/// `model.options` payload serves `providers[].models` as plain id strings
/// (#1698), so the picker and recents would render `zai/glm-5.3-flash:local`
/// verbatim; this turns it into `GLM 5.3` plus a `Flash` tag.
///
/// Display only: `ModelCatalogOption.displayName` keeps the raw id, so
/// favorite keys, selection matching, search, and the `id --provider …
/// --session` string are untouched.
enum ModelDisplayNames {
    /// The prettified name and the optional trailing tag (`Flash`, `Q4`, `1M`, …)
    /// that the desktop app renders grayed beside the name.
    struct Parts: Equatable {
        let name: String
        let tag: String
    }

    /// Trailing variant tags that keep look-alike ids apart (`…-5.3` vs
    /// `…-5.3-flash`); checked in desktop's order, so the first match wins.
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

    /// Vendors write their own names in casing the id does not carry
    /// (`glm-5.2` reads "Glm 5.2", not "GLM 5.2"). Applied after title-casing,
    /// whole words only, so `MiniMax` never touches a longer token.
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

    /// One-line picker label: the name with its tag joined by a middle dot,
    /// the way the desktop pill renders it ("GLM 5.3 · Flash"). The tag is
    /// part of the model's naming — `…-flash` and `…-thinking` must never
    /// collapse to one label.
    static func displayLabel(for modelID: String) -> String {
        let parts = parts(for: modelID)
        return parts.tag.isEmpty ? parts.name : "\(parts.name) · \(parts.tag)"
    }

    /// Origin-aware entry point for `ModelCatalogOption`. The catalog's
    /// `displayName` is the server-provided `name`/`label` when the webui
    /// transport carried one, and falls back to the raw id otherwise, so
    /// exact (case-sensitive) equality with the id is the signal that
    /// nothing was provided: only that fallback is prettified. A server
    /// name renders verbatim — the server owns that string, and "Team /
    /// Production" prettified to "Production" (or "Qwen-Max", differing
    /// from the id in case alone, to "Qwen Max") would rename someone
    /// else's model. Display only: matching by id, favorites, and the
    /// `--session` string never see this.
    static func displayLabel(for modelID: String, displayName: String) -> String {
        let parts = parts(for: modelID, displayName: displayName)
        return parts.tag.isEmpty ? parts.name : "\(parts.name) · \(parts.tag)"
    }

    /// `displayLabel(for:displayName:)` split into name and tag. A
    /// server-provided name carries no tag; the id fallback keeps the
    /// prettifier's whole pipeline.
    static func parts(for modelID: String, displayName: String) -> Parts {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-sensitive: a server name that differs from the id only by
        // case ("Qwen-Max" vs `qwen-max`) is still the server's own string,
        // not an id fallback, so it must pass through unprettified.
        guard !trimmedName.isEmpty, trimmedName != trimmedID else {
            return parts(for: modelID)
        }
        return Parts(name: displayName, tag: "")
    }

    /// Splits a model id into a clean display name plus an optional tag, so
    /// distinct ids (`…-5.3` vs `…-5.3-flash`) never produce one name.
    static func parts(for modelID: String) -> Parts {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)

        // The vendor prefix (`zai/…`) is routing, not naming.
        var base = modelBaseID(trimmed)
        // Hermes local builds carry a `:local` suffix after the model id.
        base = stripLocalSuffix(from: base)

        let split = splitTrailingTags(from: base)
        base = split.base
        var tags = [split.variant, split.quant].filter { !$0.isEmpty }

        // A `[1m]`-style route suffix selects the 1M-context window: a variant
        // of the same model, so it renders as a tag instead of raw brackets.
        if let contextWindow = firstMatch(contextWindowRegex, in: base) {
            tags.append(capture(contextWindow, 1, in: base).uppercased())
            base = before(contextWindow, in: base)
        }

        // A trailing date pin (`…-20251101`) is snapshot noise, not a name.
        base = replacingMatches(datePinRegex, in: base) { _ in "" }

        var name = prettifyBase(base)
        if name.isEmpty { name = trimmed }
        // Desktop's last resort keeps a fully empty id from rendering as "".
        if name.isEmpty { name = "No model" }
        return Parts(name: name, tag: tags.joined(separator: " "))
    }

    /// The model id without the `provider/` prefix (only for display).
    private static func modelBaseID(_ modelID: String) -> String {
        guard let slash = modelID.lastIndex(of: "/") else { return modelID }
        return String(modelID[modelID.index(after: slash)...])
    }

    private static func stripLocalSuffix(from base: String) -> String {
        guard base.lowercased().hasSuffix(":local") else { return base }
        return String(base.dropLast(":local".count))
    }

    /// Splits the trailing suffixes a local id can carry — one variant tag
    /// (`…-flash`) and one GGUF quant (`…-UD-Q4_K_XL`) — in either order:
    /// `…-flash-Q4_K_XL` and `…-Q4_K_XL-flash` are the same model.
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
                // The tag keeps the quant's FULL component: `Q4_K_M` and
                // `Q4_K_S` are different files the picker shows side by side
                // with no raw id beside the label, so truncating to the
                // family would render both as `Q4`. The `UD-` uploader
                // prefix stays too — it names a distinct build.
                quant = capture(match, 1, in: base).uppercased()
                base = before(match, in: base)
                // Instruct/chat markers are noise once the quant confirmed a local build.
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
            // Anthropic ids spell the version with hyphens (`haiku-4-5`); the
            // human name is dotted ("Haiku 4.5"), not "Haiku 4 5".
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

    /// Uppercases the first word character of every word, desktop's `\b\w`.
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
        // Parameter counts and active-parameter counts: vendors write 8B,
        // 235B, A22B — never 8b. Matched after title-casing, so the token
        // reads "8b" or "A3b", and the "A" prefix is uppercased with the "b".
        var cased = replacingMatches(parameterCountRegex, in: text) { match in
            capture(match, 1, in: text).uppercased() + capture(match, 2, in: text) + "B"
        }

        cased = replacingMatches(vendorCasingRegex, in: cased) { match in
            vendorCasing[capture(match, 1, in: cased)] ?? capture(match, 1, in: cased)
        }

        return cased
    }

    // MARK: - Regex helpers

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
    /// Desktop's `\w` word character: letters, digits, underscore.
    var isModelIDWordCharacter: Bool {
        isLetter || isNumber || self == "_"
    }
}
