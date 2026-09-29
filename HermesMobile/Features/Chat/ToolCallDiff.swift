import Foundation

/// A file edit's change, resolved from an edit-type tool call so its log row can
/// show "+N −M" and its opened body can draw #762's red and green diff rows.
/// Pure: `resolve(for:)` reads only the call, and parsed documents are cached by
/// source text, so rebuilding rows on every body pass never re-parses a diff.
struct ToolCallDiff: Equatable {
    /// Where the diff text came from, in the order `resolve(for:)` tries them.
    enum Source: Equatable {
        /// The result envelope's `diff` (hermes-agent `patch`): the real change, with context lines.
        case resultDiff
        /// A result that is itself a unified diff (MCP editors).
        case resultText
        /// An args `patch` or `diff` string.
        case argumentPatch
        /// Args `old_string`/`new_string` as removed and added lines.
        case argumentReplacement
        /// Args `content` (`write_file`) as added lines. The old file is never sent.
        case argumentContent
    }

    struct Counts: Equatable {
        let additions: Int
        /// `nil` when the source cannot know them (written content).
        let deletions: Int?
    }

    let document: MarkdownDiffDocument
    let source: Source
    /// The server cut part of the source off, so the diff is partial.
    let isTruncated: Bool
    /// The collapsed row's "+N −M"; nil when the diff would undercount the edit:
    /// a partial diff, or one `replace_all` pair standing in for every occurrence.
    let counts: Counts?
    /// Argument keys the diff stands in for in the opened body.
    let consumedArgumentKeys: Set<String>
    /// Whether the opened body drops the Result section: the diff came from the
    /// result, or the result was cut off and would show as partial raw JSON.
    let hidesResult: Bool

    /// The webui's result snippet cap (`_TOOL_RESULT_SNIPPET_MAX`). A cut result has no marker.
    private static let snippetLimit = 4_000
    /// The webui cuts content arguments at the snippet cap and appends this.
    private static let argumentCutMarker = "..."
    /// Appended when a paginated session load clips a `role: tool` message.
    private static let paginatedNotice = "\n\n[Tool output truncated in paginated session response;"
    /// Argument keys that describe the change itself rather than where it went.
    private static let changeArgumentKeys = ["patch", "diff", "old_string", "new_string", "content"]

    /// The diff for a `.write` row (names containing `write`, `patch` or `edit`), or
    /// nil when the call is not an edit, failed (the server's `is_error`, or a
    /// result reporting a failure or no-op), or carries nothing to diff. Sources,
    /// first complete one wins: the result's `diff`, a result that is a unified
    /// diff, then args `patch`/`diff`, `old_string`/`new_string`, and `content`.
    /// The args only stand in while the result is missing, cut off, or an
    /// envelope reporting success. When every source is cut off, the first one
    /// is returned as a partial diff.
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

    // MARK: - Sources

    private struct Candidate {
        let source: Source
        let text: String
        let isTruncated: Bool
        /// The argument keys it was built from; nil for a result source.
        var consumedKeys: Set<String>?
        /// A `@@ -1,<old> +1,<new> @@` line that only keeps the parser counting.
        var hasSyntheticHeader = false
        /// False when the text shows less than the edit changed, though none of it was cut.
        var hasExactCounts = true
    }

    /// What the result preview says about the edit, across the webui snippet,
    /// the paginated message fallback, and the gateway's re-encoded result.
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
                // Python slices by code point, so the cap is counted in scalars.
                // Never unescaped: a cut JSON envelope would then read as a diff.
                isCutOff = notice != nil || preview.unicodeScalars.count == ToolCallDiff.snippetLimit
                plainText = notice.map { String(preview[..<$0.lowerBound]) } ?? preview
            case .array, .number, .bool, .null:
                plainText = nil
            }

            // hermes-agent stores its one-line JSON envelope and then appends notes,
            // such as subdirectory hints, after "\n\n". A reloaded result that no
            // longer parses whole can still lead with the complete envelope.
            if let plainText, let envelope = Self.leadingEnvelope(of: plainText) {
                isCutOff = false
                read(envelope)
                return
            }

            if let plainText, ToolCallDiff.looksLikeUnifiedDiff(plainText) {
                plainDiff = plainText
            } else if !isCutOff {
                // The webui unwraps a failed edit's `error` into plain text, so any
                // other complete, non-envelope result means the args did not land.
                allowsArgumentDiff = false
            }
        }

        private mutating func read(_ envelope: [String: JSONValue]) {
            // A failed or already-applied edit changed nothing, whatever the args asked for.
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

    /// `-` lines from the old text and `+` lines from the new, behind a counted
    /// header so a line like `-- note` reads as a removal, not a `--- ` file header.
    /// A missing half is unknown (the webui keeps only the first 4 live args), so
    /// the diff is partial rather than a false "+0". With `replace_all` the pair
    /// stands for every occurrence, so it draws without counts.
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

    /// The gateway sends `replace_all` as a bool; the webui stringifies it ("True").
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

    // MARK: - Parsing

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

    /// Parsed once per source within the chat highlighter's size guards; a diff past
    /// them resolves to nothing and the row keeps its plain argument and result text.
    private static func document(for text: String) -> MarkdownDiffDocument? {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.document }
        guard MarkdownDiffFormatter.fitsSizeGuards(text) else { return nil }
        let document = MarkdownDiffFormatter.parse(text)
        cache.setObject(CacheBox(document), forKey: key)
        return document
    }

    /// Kept apart from the markdown fence cache so a turn full of edits never
    /// evicts the transcript's code blocks. `NSCache` is thread-safe and evicts
    /// under memory pressure.
    private static let cache: NSCache<NSString, CacheBox> = {
        let cache = NSCache<NSString, CacheBox>()
        cache.countLimit = 128
        return cache
    }()

    private final class CacheBox {
        let document: MarkdownDiffDocument
        init(_ document: MarkdownDiffDocument) { self.document = document }
    }

    // MARK: - Helpers

    /// Mirrors upstream `_cliLooksLikePatchDiff`: a `diff --git` line, an `@@ ` hunk
    /// line, or both `--- ` and `+++ ` lines.
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

    /// An escaped preview can leave literal `\n` sequences; a real diff always has line breaks.
    private static func unescaped(_ text: String) -> String {
        text.contains(where: \.isNewline) ? text : ToolCallDisplayFormatter.normalizedDisplayString(text)
    }

    /// A webui argument cut at the cap: exactly 4,003 code points ending in `...`.
    private static func isCutArgument(_ value: String) -> Bool {
        value.unicodeScalars.count == snippetLimit + argumentCutMarker.count && value.hasSuffix(argumentCutMarker)
    }

    private static func strippingCutMarker(_ value: String) -> String {
        isCutArgument(value) ? String(value.dropLast(argumentCutMarker.count)) : value
    }

    /// The text's lines as the diff parser splits them; a final line break ends
    /// the last line rather than starting an empty one.
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
