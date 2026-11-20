import Foundation

struct ToolCallDiff: Equatable {
    enum Source: Equatable {
        case resultDiff
        case resultText
        case argumentPatch
        case argumentReplacement
        case argumentContent
    }

    struct Counts: Equatable {
        let additions: Int
        let deletions: Int?
    }

    let document: MarkdownDiffDocument
    let source: Source
    let isTruncated: Bool
    let counts: Counts?
    let consumedArgumentKeys: Set<String>
    let hidesResult: Bool

    private static let snippetLimit = 4_000
    private static let argumentCutMarker = "..."
    private static let paginatedNotice = "\n\n[Tool output truncated in paginated session response;"
    private static let changeArgumentKeys = ["patch", "diff", "old_string", "new_string", "content"]

    static func resolve(for toolCall: ToolCall) -> ToolCallDiff? {
        guard ToolCallSummaryFormatter.kind(forToolNamed: toolCall.name) == .write,
              toolCall.isError != true
        else { return nil }

        let result = ResultReading(preview: toolCall.preview)
        guard !result.reportsNoChange else { return nil }
        let args = toolCall.args ?? [:]

        var candidates: [() -> Candidate?] = [
            { result.envelopeDiff.map { Candidate(source: .resultDiff, text: $0, isTruncated: false) } },
            { result.plainDiff.map { Candidate(source: .resultText, text: $0, isTruncated: result.isCutOff) } }
        ]
        if result.allowsArgumentDiff {
            candidates += [{ patchCandidate(args) }, { replacementCandidate(args) }, { contentCandidate(args) }]
        }

        var partial: Candidate?
        for makeCandidate in candidates {
            guard let candidate = makeCandidate() else { continue }
            if !candidate.isTruncated {
                return diff(from: candidate, args: args, resultIsCutOff: result.isCutOff)
            }
            partial = partial ?? candidate
        }
        return partial.flatMap { diff(from: $0, args: args, resultIsCutOff: result.isCutOff) }
    }

    static func resultReportsNoChange(for toolCall: ToolCall) -> Bool {
        ResultReading(preview: toolCall.preview).reportsNoChange
    }

    private struct Candidate {
        let source: Source
        let text: String
        let isTruncated: Bool
        var consumedKeys: Set<String>?
        var hasSyntheticHeader = false
        var hasExactCounts = true
    }

    private struct ResultReading {
        var envelopeDiff: String?
        var plainDiff: String?
        var isCutOff = false
        var reportsNoChange = false
        var allowsArgumentDiff = true

        init(preview: String?) {
            guard let preview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let notice = preview.range(of: ToolCallDiff.paginatedNotice)
            let parsed = notice == nil ? ToolCallDisplayFormatter.parsedJSONValue(from: preview) : nil
            let plainText: String?
            switch parsed {
            case .object(let envelope):
                read(envelope)
                return
            case .string(let string):
                plainText = ToolCallDiff.unescaped(string)
            case nil:
                isCutOff = notice != nil || preview.unicodeScalars.count == ToolCallDiff.snippetLimit
                plainText = notice.map { String(preview[..<$0.lowerBound]) } ?? preview
            case .array, .number, .bool, .null:
                plainText = nil
            }

            if let plainText, let envelope = Self.leadingEnvelope(of: plainText) {
                isCutOff = false
                read(envelope)
                return
            }

            if let plainText, ToolCallDiff.looksLikeUnifiedDiff(plainText) {
                plainDiff = plainText
            } else if !isCutOff {
                allowsArgumentDiff = false
                reportsNoChange = plainText.map(Self.looksLikeWriteError) ?? false
            }
        }

        private static let writeErrorLead = "^(?:" + [
            "could not find",
            #"found \d+ (?:approximate )?matches"#,
            "old_string is (?:empty|only whitespace)",
            "no edit was applied",
            "escape-drift detected",
            "failed to",
            "refusing to (?:write|overwrite)",
            "post-write verification failed",
            "(?:write|delete|move) denied:"
        ].joined(separator: "|") + ")"

        private static func looksLikeWriteError(_ text: String) -> Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: writeErrorLead, options: [.regularExpression, .caseInsensitive]) != nil
        }

        private mutating func read(_ envelope: [String: JSONValue]) {
            reportsNoChange = Self.hasValue(envelope["error"])
                || envelope["success"] == .bool(false)
                || envelope["no_change"] == .bool(true)
            if case .string(let diff) = envelope["diff"], !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                envelopeDiff = ToolCallDiff.unescaped(diff)
            }
        }

        private static func leadingEnvelope(of text: String) -> [String: JSONValue]? {
            guard let lineEnd = text.firstIndex(where: \.isNewline),
                  case .object(let envelope)? = ToolCallDisplayFormatter.parsedJSONValue(from: String(text[..<lineEnd]))
            else { return nil }
            return envelope
        }

        private static func hasValue(_ value: JSONValue?) -> Bool {
            switch value {
            case nil, .null?: false
            case .string(let text)?: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: true
            }
        }
    }

    private static func patchCandidate(_ args: [String: JSONValue]) -> Candidate? {
        for key in ["patch", "diff"] {
            guard case .string(let value)? = args[key],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return Candidate(
                source: .argumentPatch,
                text: strippingCutMarker(value),
                isTruncated: isCutArgument(value),
                consumedKeys: [key]
            )
        }
        return nil
    }

    private static func replacementCandidate(_ args: [String: JSONValue]) -> Candidate? {
        let old = string(args["old_string"])
        let new = string(args["new_string"])
        guard old != nil || new != nil else { return nil }

        let removed = lines(of: old.map(strippingCutMarker) ?? "").map { "-" + $0 }
        let added = lines(of: new.map(strippingCutMarker) ?? "").map { "+" + $0 }
        guard !removed.isEmpty || !added.isEmpty else { return nil }

        return Candidate(
            source: .argumentReplacement,
            text: (["@@ -1,\(removed.count) +1,\(added.count) @@"] + removed + added).joined(separator: "\n"),
            isTruncated: old == nil || new == nil || old.map(isCutArgument) == true || new.map(isCutArgument) == true,
            consumedKeys: Set(["old_string", "new_string"].filter { args[$0] != nil }),
            hasSyntheticHeader: true,
            hasExactCounts: !replacesAll(args)
        )
    }

    private static func replacesAll(_ args: [String: JSONValue]) -> Bool {
        switch args["replace_all"] {
        case .bool(let value)?: value
        case .string(let value)?: value.lowercased() == "true"
        default: false
        }
    }

    private static func contentCandidate(_ args: [String: JSONValue]) -> Candidate? {
        guard let content = string(args["content"]) else { return nil }
        let added = lines(of: strippingCutMarker(content)).map { "+" + $0 }
        guard !added.isEmpty else { return nil }

        return Candidate(
            source: .argumentContent,
            text: (["@@ -1,0 +1,\(added.count) @@"] + added).joined(separator: "\n"),
            isTruncated: isCutArgument(content),
            consumedKeys: ["content"],
            hasSyntheticHeader: true
        )
    }

    private static func diff(from candidate: Candidate, args: [String: JSONValue], resultIsCutOff: Bool) -> ToolCallDiff? {
        let text = droppingFinalLineBreak(candidate.text)
        guard let parsed = document(for: text) else { return nil }

        let usesResult = candidate.consumedKeys == nil
        let document = candidate.hasSyntheticHeader
            ? MarkdownDiffDocument(lines: Array(parsed.lines.dropFirst()), additions: parsed.additions, deletions: parsed.deletions)
            : parsed
        let counts = candidate.isTruncated || !candidate.hasExactCounts ? nil : Counts(
            additions: document.additions,
            deletions: candidate.source == .argumentContent ? nil : document.deletions
        )
        return ToolCallDiff(
            document: document,
            source: candidate.source,
            isTruncated: candidate.isTruncated,
            counts: counts,
            consumedArgumentKeys: candidate.consumedKeys
                ?? Set(changeArgumentKeys.filter { string(args[$0]) != nil }),
            hidesResult: usesResult || resultIsCutOff
        )
    }

    private static func document(for text: String) -> MarkdownDiffDocument? {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.document }
        guard MarkdownDiffFormatter.fitsSizeGuards(text) else { return nil }
        let document = MarkdownDiffFormatter.parse(text)
        cache.setObject(CacheBox(document), forKey: key)
        return document
    }

    private static let cache: NSCache<NSString, CacheBox> = {
        let cache = NSCache<NSString, CacheBox>()
        cache.countLimit = 128
        return cache
    }()

    private final class CacheBox {
        let document: MarkdownDiffDocument
        init(_ document: MarkdownDiffDocument) { self.document = document }
    }

    private static func looksLikeUnifiedDiff(_ text: String) -> Bool {
        var hasOldHeader = false
        var hasNewHeader = false
        var looksLikeDiff = false
        text.enumerateLines { line, stop in
            hasOldHeader = hasOldHeader || line.hasPrefix("--- ")
            hasNewHeader = hasNewHeader || line.hasPrefix("+++ ")
            looksLikeDiff = line.hasPrefix("diff --git ") || line.hasPrefix("@@ ") || (hasOldHeader && hasNewHeader)
            stop = looksLikeDiff
        }
        return looksLikeDiff
    }

    private static func unescaped(_ text: String) -> String {
        text.contains(where: \.isNewline) ? text : ToolCallDisplayFormatter.normalizedDisplayString(text)
    }

    private static func isCutArgument(_ value: String) -> Bool {
        value.unicodeScalars.count == snippetLimit + argumentCutMarker.count && value.hasSuffix(argumentCutMarker)
    }

    private static func strippingCutMarker(_ value: String) -> String {
        isCutArgument(value) ? String(value.dropLast(argumentCutMarker.count)) : value
    }

    private static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return MarkdownPlainCodeFormatter.rawLines(in: droppingFinalLineBreak(text))
    }

    private static func droppingFinalLineBreak(_ text: String) -> String {
        text.last?.isNewline == true ? String(text.dropLast()) : text
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }
}
