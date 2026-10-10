import Foundation

/// A Hermes session's settled history as its REST transcript pages bring it (#1047): display
/// rows in the host's order, the newest rows first, older pages put in front. A row's `id` is
/// the host's `messages.id`. It names the row on every page, but ids do not follow display
/// order (a compaction re-inserts the session's first rows under new ids), so pages join by
/// position and repeat rows drop by id. `offset` counts display rows back from the newest, so
/// rows the host saved since the newest rows were taken shift every older page: the chat takes
/// the newest rows again, or counts them while a turn runs, before it pages back.
struct HermesTranscriptHistory: Equatable {
    private(set) var rows: [BotJSON] = []
    /// Earlier rows remain on the host: the last page read was a full one.
    private(set) var hasOlder = false
    private var ids: Set<Int> = []
    /// Rows the host saved after the newest row held, as last counted: a running turn's, which
    /// the chat shows as they stream.
    private var newer = 0
    /// A full older page added nothing: rows the chat never counted pushed the rows held into
    /// it. The next page waits until the newest rows are read again.
    private(set) var needsRecount = false
    /// What the last newest read covered, for the offline cache (#1054); nil until one succeeds.
    private(set) var newestCoverage: HermesNewestCoverage?

    /// Where the next older page starts: the display rows held and the newer ones, counted
    /// from the newest.
    var nextOffset: Int { rows.count + newer }

    /// Whether newest rows read back from offset 0 reach the rows held, so they leave no hole:
    /// they share a row, or none is held.
    func reaches(_ rows: [BotJSON]) -> Bool {
        ids.isEmpty || rows.contains { Self.id($0).map(ids.contains) == true }
    }

    func holds(_ id: Int) -> Bool { ids.contains(id) }

    /// Takes the newest rows: pages read back from offset 0 until they reached the rows held,
    /// oldest first. They replace the rows held from the first row they share, which also drops
    /// rows the host stopped showing there, and keep the older ones. When they reached the first
    /// row, or share none, the history starts again from them.
    mutating func mergeNewest(_ fresh: [BotJSON], reachedStart: Bool) {
        var seen = Set<Int>()
        let fresh = fresh.filter { Self.id($0).map { seen.insert($0).inserted } == true }
        let freshIDs = fresh.compactMap(Self.id)
        newestCoverage = reachedStart ? .all : freshIDs.isEmpty ? nil : .from(rowIDs: freshIDs)
        if !reachedStart, let shared = rows.firstIndex(where: { Self.id($0).map(seen.contains) == true }) {
            replace(with: rows[..<shared].filter { Self.id($0).map(seen.contains) == false } + fresh)
        } else {
            replace(with: fresh)
            hasOlder = !reachedStart
        }
        newer = 0
        needsRecount = false
    }

    /// Counts the rows read back from offset 0 after the newest one held, without taking them.
    /// Returns false when they hold none, so the count is unknown.
    mutating func countNewer(in fresh: [BotJSON]) -> Bool {
        var seen = Set<Int>()
        let fresh = fresh.filter { Self.id($0).map { seen.insert($0).inserted } == true }
        guard let last = fresh.lastIndex(where: { Self.id($0).map(ids.contains) == true }) else { return false }
        newer = fresh.count - 1 - last
        needsRecount = false
        return true
    }

    /// Puts the page read at `nextOffset` in front: its rows before the first row already held,
    /// since a page is oldest first and rows saved meanwhile push held rows into it. Returns
    /// whether it added any. A short page reached the first row. A full one that added nothing
    /// met the rows held, so more rows were saved than counted (`needsRecount`).
    @discardableResult
    mutating func prependOlder(_ page: [BotJSON]) -> Bool {
        var seen = ids
        let older = page.prefix { Self.id($0).map(ids.contains) != true }
            .filter { row in Self.id(row).map { seen.insert($0).inserted } == true }
        replace(with: older + rows)
        hasOlder = page.count >= HermesREST.transcriptPageSize
        needsRecount = hasOlder && older.isEmpty
        return !older.isEmpty
    }

    /// Drops row `id` and every row after it, as the host's rewind did (#1049). The rows the
    /// host saved since are unknown, so the next older page waits for a newest read.
    mutating func cut(before id: Int) {
        guard let index = rows.firstIndex(where: { Self.id($0) == id }) else { return }
        replace(with: Array(rows[..<index]))
        needsRecount = true
    }

    private mutating func replace(with rows: [BotJSON]) {
        self.rows = rows
        ids = Set(rows.compactMap(Self.id))
    }

    static func id(_ row: BotJSON) -> Int? { row["id"].integer }
}

/// The part of a Hermes transcript a newest read covered (#1054): every row once it reached the
/// first, else its rows, oldest first, and every row the host shows after them. Ids don't follow
/// display order (a compaction re-inserts the first rows under new ids), so the part is placed by
/// position, never by an id range. A row the offline cache holds there, which the read lacks, was
/// cut on the host, by a rewind or an undo.
enum HermesNewestCoverage: Equatable {
    case all
    case from(rowIDs: [Int])
}

/// Fork From Here's `count` for `session.branch` (#1051): the host keeps the first `count` rows
/// of its visible history, the user and assistant rows of its display projection whose content
/// has text (`_visible_branch_history`, `tui_gateway/methods_session.py`). A transcript page is
/// that projection, so the count is the rows from the session's first one through the chosen
/// one that pass the same test. Compacted rows and the hidden compaction summary count, and
/// tool rows never do: on `scripts/local-hermes` at the pin, a branch counted this way ended at
/// the chosen row after tool turns and on both sides of an in-place compaction.
enum HermesBranchCount {
    /// The count through row `rowID` of `rows`, which must run from the session's first row;
    /// nil when no such row is there, or it is one the host never copies.
    static func count(through rowID: Int, in rows: [BotJSON]) -> Int? {
        var count = 0
        for row in rows {
            let counts = copies(row)
            if counts { count += 1 }
            if HermesTranscriptHistory.id(row) == rowID { return counts ? count : nil }
        }
        return nil
    }

    private static func copies(_ row: BotJSON) -> Bool {
        guard let role = row["role"].text, role == "user" || role == "assistant" else { return false }
        return hasText(row["content"])
    }

    /// Whether `content` has text as the host reads it (`_coerce_message_text`): a string, a
    /// part's text, or any other typed part, such as an image, which reads as a mark like `[image]`.
    private static func hasText(_ content: BotJSON) -> Bool {
        switch content {
        case .string(let text): return isText(text)
        case .array(let parts):
            return parts.contains { part in
                if let text = part.text ?? part["text"].text { return isText(text) }
                return part["type"].text.map { objectHasText(part, kind: $0) } ?? false
            }
        case .object: return objectHasText(content, kind: content["type"].text)
        case .null: return false
        case .number, .bool: return true
        }
    }

    /// `_history_dict_text`: a text kind's own text, a mark for any other kind, and an untyped
    /// object's `text`, else a mark too.
    private static func objectHasText(_ object: BotJSON, kind: String?) -> Bool {
        guard let kind else { return object.fields?["text"].map { isText($0.text) } ?? true }
        return !["text", "input_text", "output_text"].contains(kind) || isText(object["text"].text ?? object["content"].text)
    }

    private static func isText(_ text: String?) -> Bool {
        text?.contains { !$0.isWhitespace } == true
    }
}

/// Where a compacted Hermes session's "Context compaction · Reference only" card sits (#1047):
/// right after `anchorMessageID`, the last message before the host's summary row, or above the
/// rows loaded when none precedes it. The rows before it are the compacted turns.
struct HermesCompaction: Equatable {
    let referenceText: String
    let anchorMessageID: String?
}

/// A Hermes session's REST transcript rows as the main chat shows them (#1047). Bot Chat keeps
/// `BotTranscriptProjection`, which reads `session.resume`'s snapshot rows.
///
/// A row's message id is `<stored key>/row-<id>` and its `rowID` the host's id, so a reload, a
/// turn's end and a later cache agree on identity; a row compaction archived (`active` 0) is
/// `isCompacted`, since the host cuts only in its live history (#1049). A `tool` row carries the full output; it joins
/// the call its assistant row declared (`tool_calls`, matched by `tool_call_id`), named by the
/// host's `tool_call_labels` when it sent any. Tool rows and reasoning settle in front of the next
/// message, as in Bot Chat. `display_kind` is open: `hidden` never shows, a steer is unwrapped,
/// `async_delegation_complete` is the delegation completion row, and any other kind, such as
/// `failed_turn`, shows its text by role. The host's `display_content`, `display_commentary` and
/// `display_reasoning` already project the `codex_*` columns, which are never read. User rows that
/// open with `[System:` are the gateway's notices and stay hidden, as `session.resume` hides them.
/// A skill turn's stored row is the expanded skill; it shows as the line the user typed, which
/// `session.resume` projects and a REST page does not (`skillInvocation`).
enum HermesTranscriptProjection {
    struct Result: Equatable {
        var messages: [ChatMessage] = []
        var toolCallGroups: [ToolCallGroup] = []
        var reasoningGroups: [ReasoningGroup] = []
        var compaction: HermesCompaction?
    }

    static func project(_ rows: [BotJSON], root: String) -> Result {
        var result = Result()
        var tools: [ToolCall] = []
        var reasoning: [String] = []
        var pendingStart: Int?
        // Each declared call's name and arguments, for the tool row that answers it.
        var calls: [String: (name: String?, args: [String: JSONValue]?)] = [:]

        func flush(anchor: String?) {
            guard let start = pendingStart else { return }
            if !tools.isEmpty {
                result.toolCallGroups.append(ToolCallGroup(id: "\(root)/row-\(start)/tools", anchorMessageID: anchor, toolCalls: tools))
            }
            if !reasoning.isEmpty {
                result.reasoningGroups.append(ReasoningGroup(id: "\(root)/row-\(start)/reasoning", anchorMessageID: anchor,
                                                             text: reasoning.joined(separator: "\n\n")))
            }
            tools = []; reasoning = []; pendingStart = nil
        }

        for row in rows {
            guard let rowID = HermesTranscriptHistory.id(row), let role = row["role"].text else { continue }
            let kind = row["display_kind"].text
            if row["_compressed_summary"].flag == true {
                // The latest summary places the card; the rows before it are the compacted turns.
                // Only the real content the host found inside it (`display_content`) is a row.
                result.compaction = HermesCompaction(referenceText: summary(row["content"].text ?? ""),
                                                     anchorMessageID: result.messages.last?.messageId)
                guard row["display_content"].text != nil else { continue }
            }
            guard kind != "hidden" else { continue }
            switch role {
            case "tool":
                pendingStart = pendingStart ?? rowID
                let call = row["tool_call_id"].text.flatMap { calls[$0] }
                tools.append(ToolCall(
                    id: "\(root)/row-\(rowID)", name: call?.name ?? row["tool_name"].text,
                    preview: BotTurnActivity.resultPreview(row["content"]), args: call?.args, isCompleted: true,
                    startedAt: row["timestamp"].number ?? 0
                ))
            case "assistant", "user":
                if role == "assistant" {
                    for call in row["tool_calls"].list ?? [] {
                        guard let id = call["id"].text ?? call["call_id"].text else { continue }
                        calls[id] = (toolName(call, labels: row["tool_call_labels"][id]), arguments(call["function"]["arguments"]))
                    }
                    let thought = row["display_reasoning"].text ?? row["reasoning"].text ?? row["reasoning_content"].text
                    if let thought, !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pendingStart = pendingStart ?? rowID
                        reasoning.append(thought)
                    }
                }
                let text = Self.text(row)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      role == "assistant" || !text.drop(while: \.isWhitespace).hasPrefix("[System:") else { continue }
                let id = "\(root)/row-\(rowID)"
                flush(anchor: id)
                let isDelegationCompletion = kind == HermesDelegationCompletion.displayKind
                // A steer is stored inside the out-of-band marker; unwrapped first, the trailing
                // mention note is still a suffix and is hidden as on any other user row.
                let steer = role == "user" ? ChatMessage.strippedSteerText(from: text) : nil
                let skill = role == "user" ? skillInvocation(text) : nil
                result.messages.append(ChatMessage(
                    role: isDelegationCompletion ? "delegation_completion" : role,
                    content: skill ?? (role == "user" && !isDelegationCompletion ? BotMentions.displayText(steer ?? text) : text),
                    timestamp: row["timestamp"].number,
                    messageId: id,
                    displayKind: steer != nil ? ChatMessage.steerDisplayKind : kind ?? (skill == nil ? nil : "skill_invocation"),
                    displayMetadata: row["display_metadata"].argumentDictionary,
                    rowID: rowID,
                    isCompacted: row["active"].integer == 0
                ))
            default:
                continue
            }
        }
        flush(anchor: nil)
        return result
    }

    /// A row's shown text: the host's `display_content` when it sent one, else `content` (a
    /// string, or the text of a parts list), after any public commentary the host projected.
    private static func text(_ row: BotJSON) -> String {
        let body: String
        if let shown = row["display_content"].text {
            body = shown
        } else if let parts = row["content"].list {
            body = parts.compactMap { $0.text ?? $0["text"].text }.joined()
        } else {
            body = row["content"].text ?? ""
        }
        let commentary = (row["display_commentary"].list ?? []).compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let joined = commentary.joined(separator: "\n\n")
        guard !commentary.isEmpty, joined.trimmingCharacters(in: .whitespacesAndNewlines)
            != body.trimmingCharacters(in: .whitespacesAndNewlines) else { return body }
        return ([joined] + (body.isEmpty ? [] : [body])).joined(separator: "\n\n")
    }

    /// The line a skill turn's user typed, from the expanded skill the host stored: `/name` and
    /// any instruction, or a stacked bundle's `/a /b` and its instruction. Nil for any other
    /// text. A port of `describe_skill_invocation` (`agent/skill_commands.py`) at the pin, whose
    /// markers are the host's builders' own.
    static func skillInvocation(_ text: String) -> String? {
        guard let head = text.range(of: "[IMPORTANT: The user has invoked the ", options: .anchored) else { return nil }
        let quoted = text[head.upperBound...]
        var name = ""
        if quoted.first == "\"", let close = quoted.dropFirst().firstIndex(of: "\"") {
            name = quoted[quoted.index(after: quoted.startIndex)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The text between a marker and the next stop marker.
        func cut(after marker: String, before stop: String, last: Bool = false) -> Substring {
            guard let start = text.range(of: marker, options: last ? .backwards : [])?.upperBound else { return "" }
            let tail = text[start...]
            return tail[..<(tail.range(of: stop)?.lowerBound ?? tail.endIndex)]
        }
        // A bundle's instruction comes before its skills. A single skill's follows the skill's
        // body, which may quote the marker, so the last one is the user's.
        let instruction = text.contains(" skill bundle,")
            ? cut(after: "\nUser instruction: ", before: "\n\n[Loaded as part of the ")
            : text.contains("The full skill content is loaded below.]")
            ? cut(after: "The user has provided the following instruction alongside the skill invocation: ",
                  before: "\n\n[Runtime note:", last: true)
            : ""
        let words = instruction.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let label = name.hasPrefix("/") ? name : "/\(name)"
        if !words.isEmpty { return name.isEmpty ? words : "\(label) \(words)" }
        return name.isEmpty ? nil : label
    }

    /// A declared call's name: its labels' text (a bridge call such as `tool_call` names the
    /// tools it ran), else the function's own name.
    private static func toolName(_ call: BotJSON, labels: BotJSON) -> String? {
        let named = (labels.list ?? []).compactMap { $0["text"].text ?? $0["name"].text }.filter { !$0.isEmpty }
        return named.isEmpty ? call["function"]["name"].text : named.joined(separator: ", ")
    }

    /// A call's arguments: a JSON string as the provider sent it, or an object.
    private static func arguments(_ value: BotJSON) -> [String: JSONValue]? {
        guard let text = value.text else { return value.argumentDictionary }
        return (try? JSONDecoder().decode(BotJSON.self, from: Data(text.utf8)))?.argumentDictionary
    }

    /// The summary a compaction handoff carries, for the card: after any prior context the host
    /// merged in front of it, without the handoff's first line (the host's instructions to the
    /// model) and its end marker.
    static func summary(_ content: String) -> String {
        var text = Substring(content)
        if let merged = text.range(of: "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]") {
            text = text[merged.upperBound...]
        }
        text = text.drop(while: \.isWhitespace)
        if ChatMarkerMessageClassifier.isContextCompactionText(String(text)) {
            text = text.firstIndex(of: "\n").map { text[$0...] } ?? ""
        }
        if let end = text.range(of: "--- END OF CONTEXT SUMMARY") { text = text[..<end.lowerBound] }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
