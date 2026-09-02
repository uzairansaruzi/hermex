import Foundation

/// One settled tool call reduced to a log line: icon, bold verb, dim one-line
/// detail, and a status glyph. Built by `ToolCallSummaryFormatter`.
struct ToolCallLogRow: Equatable {
    enum Status: Equatable {
        case success
        case failure
        /// The group settled before the call ever reported completion.
        case interrupted
    }

    /// SF Symbol for the leading icon column.
    let icon: String
    /// The verb ("Ran", "Read", …) or, for unrecognised tools, the short tool name.
    let summary: String
    /// The call's target (command, file, query, skill) or the first result line.
    let detail: String?
    let status: Status

    var isFailure: Bool { status == .failure }

    var statusText: String {
        switch status {
        case .success: String(localized: "Completed")
        case .failure: String(localized: "Failed")
        case .interrupted: String(localized: "Interrupted")
        }
    }
}

/// A tool call paired with its log row, keyed by the call's id for `ForEach`.
struct ToolCallLogEntry: Identifiable, Equatable {
    let toolCall: ToolCall
    let row: ToolCallLogRow

    var id: String { toolCall.id }
}

/// Turns settled tool calls into one-line log rows. The rules mirror the upstream
/// web UI's compact tool labels (`_toolActionKind` / `_toolTargetLabel` in
/// `static/ui.js`) so a call reads the same on the phone and in the browser.
/// Pure and stateless so every rule is unit-testable.
enum ToolCallSummaryFormatter {
    enum Kind: Equatable {
        case shell, read, write, search, web, list, skill, memory, delegate, unknown
    }

    private static let detailLimit = 160

    /// Rows for a settled group, in call order. Calls with nothing to say (no
    /// name, target, or result) are dropped; failures are never dropped.
    static func entries(for toolCalls: [ToolCall]) -> [ToolCallLogEntry] {
        toolCalls.compactMap { toolCall in
            row(for: toolCall).map { ToolCallLogEntry(toolCall: toolCall, row: $0) }
        }
    }

    /// The log row for one call, or `nil` when the call carries no signal.
    static func row(for toolCall: ToolCall) -> ToolCallLogRow? {
        let name = nonEmpty(toolCall.name)
        let toolKind = kind(forToolNamed: name)
        let resultText = resultText(for: toolCall)
        let rowStatus = status(for: toolCall, kind: toolKind, resultText: resultText)
        let detail = targetDetail(kind: toolKind, name: name, args: toolCall.args)
            ?? resultText.flatMap(firstLine)

        guard rowStatus == .failure || name != nil || detail != nil else {
            return nil
        }

        return ToolCallLogRow(
            icon: icon(kind: toolKind, name: name),
            summary: summary(kind: toolKind, name: name),
            detail: detail,
            status: rowStatus
        )
    }

    /// Everything a long-press puts on the pasteboard: the row line, then the
    /// same arguments and result the expanded body shows.
    static func copyText(for toolCall: ToolCall) -> String {
        var lines: [String] = []
        if let row = row(for: toolCall) {
            lines.append([row.summary, row.detail].compactMap { $0 }.joined(separator: " "))
        }

        let content = ToolCallDisplayFormatter.content(for: toolCall)
        lines += content.argumentRows.map { "\($0.key): \($0.value)" }
        if let result = content.result {
            lines.append(result.text)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Kind and presentation

    static func kind(forToolNamed rawName: String?) -> Kind {
        let name = normalizedName(rawName)
        guard !name.isEmpty else { return .unknown }

        if name == "subagent_progress" || name == "delegate_task" { return .delegate }
        if name.contains("skill") { return .skill }
        if name.contains("memory") { return .memory }
        if name.contains("terminal") || name.contains("shell") || name.contains("command")
            || name.contains("process") || name == "execute_code" {
            return .shell
        }
        if name.contains("read") || name.contains("view") || name.contains("open") || name == "vision_analyze" {
            return .read
        }
        if name.contains("list") || name == "todo" { return .list }
        if name.contains("web") || name.contains("fetch") || name.contains("curl")
            || name.contains("extract") || name.contains("browse") || name.contains("navigate") {
            return .web
        }
        if name.contains("search") || name.contains("grep") || name.contains("find") { return .search }
        if name.contains("write") || name.contains("patch") || name.contains("edit") { return .write }
        return .unknown
    }

    private static func summary(kind: Kind, name: String?) -> String {
        switch kind {
        case .shell: String(localized: "Ran")
        case .read: String(localized: "Read")
        case .write: String(localized: "Updated")
        case .search: String(localized: "Searched")
        case .web: String(localized: "Checked")
        case .list: String(localized: "Listed")
        case .skill: String(localized: "Loaded")
        case .memory: String(localized: "Saved")
        case .delegate: String(localized: "Delegated")
        case .unknown: shortToolName(name)
        }
    }

    private static func icon(kind: Kind, name: String?) -> String {
        let normalized = normalizedName(name)
        if normalized.hasPrefix("mcp_") { return "powerplug" }

        switch normalized {
        case "execute_code": return "play"
        case "todo": return "checklist"
        case "cronjob": return "clock"
        case "send_message": return "bubble.left"
        case "vision_analyze": return "eye"
        default: break
        }

        switch kind {
        case .shell: return "terminal"
        case .read: return "doc.text"
        case .write: return "pencil.line"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .list: return "list.bullet"
        case .skill: return "book"
        case .memory: return "brain"
        case .delegate: return "arrow.triangle.branch"
        case .unknown: return "wrench"
        }
    }

    /// `mcp__server__tool` reads as `server/tool`; anything else is the raw name.
    static func shortToolName(_ rawName: String?) -> String {
        guard let name = nonEmpty(rawName) else { return String(localized: "Tool") }

        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "__").map(String.init).filter { !$0.isEmpty }
            if parts.count > 1 { return parts.dropFirst().joined(separator: "/") }
        }
        if name.hasPrefix("mcp.") {
            let parts = name.split(separator: ".").map(String.init).filter { !$0.isEmpty }
            if parts.count > 1 { return parts.dropFirst().joined(separator: "/") }
        }
        return name
    }

    // MARK: - Detail

    private static func targetDetail(kind: Kind, name: String?, args: [String: JSONValue]?) -> String? {
        guard let args, !args.isEmpty else { return nil }

        switch kind {
        case .shell:
            return firstString(in: args, keys: ["cmd", "command"])
                .map(unwrappingShellWrapper)
                .flatMap(compacted)
        case .skill:
            return firstString(in: args, keys: ["name", "skill"]).flatMap(compacted)
        case .memory:
            return firstString(in: args, keys: ["target", "name", "action"]).flatMap(compacted)
        case .read:
            guard let path = firstString(in: args, keys: ["path", "file_path", "file", "target", "name"]) else {
                return nil
            }
            let fileName = basename(path)
            if normalizedName(name) == "read_file", let range = readRange(args: args) {
                return compacted("\(range) · \(fileName)")
            }
            return compacted(fileName)
        case .write:
            return changedFilesPreview(args: args)
        case .search, .web:
            return firstString(in: args, keys: ["query", "pattern", "url", "uri"]).flatMap(compacted)
        case .list, .delegate, .unknown:
            return firstString(
                in: args,
                keys: ["cmd", "command", "path", "file_path", "file", "uri", "url", "query", "pattern", "dir", "task", "name"]
            )
            .flatMap(compacted)
        }
    }

    /// `L12-40 · File.swift` style range for `read_file` offset/limit arguments.
    private static func readRange(args: [String: JSONValue]) -> String? {
        guard let offset = integer(args["offset"]), offset > 0 else { return nil }
        guard let limitValue = args["limit"] else { return "L\(offset)" }
        guard let limit = integer(limitValue), limit > 0 else { return nil }
        guard limit > 1 else { return "L\(offset)" }
        let (end, overflow) = offset.addingReportingOverflow(limit - 1)
        return overflow ? nil : "L\(offset)-\(end)"
    }

    /// First changed file plus `+N more`, from the same path arguments the
    /// per-turn file recap reads (`path`, `paths[]`, `edits[].path`, …).
    static func changedFilesPreview(args: [String: JSONValue]) -> String? {
        var paths: [String] = []
        func append(_ value: JSONValue?) {
            if let string = string(value), !paths.contains(string) {
                paths.append(string)
            }
        }

        for key in ["path", "file_path", "file", "target", "destination", "name"] {
            append(args[key])
        }
        if case .array(let items)? = args["paths"] {
            items.forEach(append)
        }
        if case .array(let edits)? = args["edits"] {
            for edit in edits {
                if case .object(let object) = edit {
                    append(object["path"])
                }
            }
        }

        guard let first = paths.first else { return nil }
        let remaining = paths.count - 1
        guard remaining > 0 else { return compacted(basename(first)) }
        return compacted("\(basename(first)) \(String(localized: "+\(remaining) more"))")
    }

    /// `bash -lc "git status"`, `pwsh -Command "…"`, and `cmd /c …` read as the
    /// inner command. Anything else is returned untouched.
    static func unwrappingShellWrapper(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = trimmed.firstIndex(where: \.isWhitespace) else { return command }

        let executable = executableBasename(String(trimmed[..<split]))
        let rest = trimmed[split...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return command }

        let flagPattern: String
        switch executable {
        case "pwsh", "powershell": flagPattern = #"(?:^|\s)-command\s+"#
        case "cmd": flagPattern = #"(?:^|\s)/c\s+"#
        case "bash", "sh", "zsh": flagPattern = #"(?:^|\s)-(?:l)?c\s+"#
        default: return command
        }

        guard let regex = try? NSRegularExpression(pattern: flagPattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let matchRange = Range(match.range, in: rest)
        else {
            return command
        }

        let inner = rest[matchRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return command }
        let unquoted = trimmingMatchingOuterQuotes(inner)
        return unquoted.isEmpty ? command : unquoted
    }

    private static func executableBasename(_ executable: String) -> String {
        var name = executable.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? executable
        name = name.lowercased()
        if name.hasSuffix(".exe") { name.removeLast(4) }
        return name
    }

    private static func trimmingMatchingOuterQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'"
        else {
            return value
        }
        return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Status

    /// The server's `is_error` verdict wins whenever the call carries one
    /// (every live completion, and persisted transcripts that store it). A call
    /// with no verdict falls back to its result: the JSON envelope's `error` /
    /// `exit_code` first, then the text heuristics. Search and web results are
    /// never judged by text, since their output is whatever the query matched.
    private static func status(for toolCall: ToolCall, kind: Kind, resultText: String?) -> ToolCallLogRow.Status {
        switch toolCall.isError {
        case true?:
            return .failure
        case false?:
            break
        case nil:
            if let envelopeFailure = ToolCallDisplayFormatter.envelopeReportsFailure(preview: toolCall.preview) {
                if envelopeFailure { return .failure }
            } else if let resultText, kind != .search, kind != .web, looksLikeFailure(resultText) {
                return .failure
            }
        }
        return toolCall.isCompleted ? .success : .interrupted
    }

    /// Splits a trailing `<exited with exit code N>` marker off tool output.
    static func strippingTrailingExitCode(_ text: String) -> (output: String?, exitCode: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^([\s\S]*?)(?:\s*<exited with exit code (\d+)>)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let outputRange = Range(match.range(at: 1), in: trimmed),
              let codeRange = Range(match.range(at: 2), in: trimmed)
        else {
            return (nonEmpty(trimmed), nil)
        }

        let output = trimmed[outputRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return (nonEmpty(output), Int(trimmed[codeRange]))
    }

    /// Text-only failure signals for a call with no server verdict and no JSON
    /// envelope. A trailing `<exited with exit code N>` marker is decisive either
    /// way. Otherwise only the first line of output is read, which is where
    /// shells and file tools put their error, so a call that merely mentions
    /// "not found" further down its output stays green.
    static func looksLikeFailure(_ text: String) -> Bool {
        let stripped = strippingTrailingExitCode(text)
        if let exitCode = stripped.exitCode {
            return exitCode != 0
        }

        guard let firstLine = (stripped.output ?? "")
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        else {
            return false
        }

        if firstLine.hasPrefix("error:") { return true }

        let phrases = [
            "file not found", "no files found", "enoent", "no such file or directory", "no such file",
            "commandnotfoundexception", "command not found",
            "is not recognized as the name of a cmdlet",
            "a parameter cannot be found that matches parameter name"
        ]
        if phrases.contains(where: { firstLine.contains($0) }) { return true }
        if firstLine.contains("cannot find path"), firstLine.contains("because it does not exist") { return true }
        if firstLine.contains("is not recognized"), firstLine.contains("the term '") { return true }
        return false
    }

    // MARK: - Helpers

    /// The unwrapped result the expanded body shows, minus the exit-code marker.
    private static func resultText(for toolCall: ToolCall) -> String? {
        guard let display = ToolCallDisplayFormatter.resultDisplay(preview: toolCall.preview, toolName: toolCall.name) else {
            return nil
        }
        return display.text
    }

    private static func firstLine(_ text: String) -> String? {
        let stripped = strippingTrailingExitCode(text).output ?? text
        for line in stripped.split(whereSeparator: \.isNewline) {
            if let compactLine = compacted(String(line)) { return compactLine }
        }
        return nil
    }

    /// Collapses whitespace to single spaces and caps the length for one line.
    private static func compacted(_ text: String) -> String? {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > detailLimit else { return collapsed }
        return String(collapsed.prefix(detailLimit - 1)) + "…"
    }

    private static func basename(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return components.last.map(String.init) ?? trimmed
    }

    private static func normalizedName(_ rawName: String?) -> String {
        let lowered = (rawName ?? "").lowercased()
        var result = ""
        var pendingUnderscore = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                if pendingUnderscore, !result.isEmpty { result.append("_") }
                pendingUnderscore = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingUnderscore = true
            }
        }
        return result
    }

    private static func firstString(in args: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = string(args[key]) { return value }
        }
        return nil
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return nonEmpty(string)
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .number(let number)?:
            guard number.isFinite, number == number.rounded(.towardZero) else { return nil }
            return Int(exactly: number)
        case .string(let string)?:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
