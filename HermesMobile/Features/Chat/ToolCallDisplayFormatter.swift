import Foundation

struct ToolCallDisplayContent: Equatable {
    let argumentRows: [ToolCallArgumentDisplay]
    let result: ToolCallResultDisplay?
}

struct ToolCallArgumentDisplay: Identifiable, Equatable {
    let key: String
    let value: String

    var id: String { key }
}

struct ToolCallResultDisplay: Equatable {
    let title: String
    let text: String
    let isMonospaced: Bool
}

enum ToolCallDisplayFormatter {
    static func content(for toolCall: ToolCall) -> ToolCallDisplayContent {
        ToolCallDisplayContent(
            argumentRows: argumentRows(from: toolCall.args),
            result: resultDisplay(preview: toolCall.preview, toolName: toolCall.name)
        )
    }

    static func argumentRows(from args: [String: JSONValue]?) -> [ToolCallArgumentDisplay] {
        (args ?? [:])
            .sorted { $0.key < $1.key }
            .map { key, value in
                ToolCallArgumentDisplay(key: key, value: value.toolDisplayText)
            }
    }

    static func resultDisplay(preview: String?, toolName: String?) -> ToolCallResultDisplay? {
        guard let preview = nonEmpty(preview) else { return nil }

        let parsedValue = parsedJSONValue(from: preview)
        let parsedText = parsedValue.flatMap { readableResultText(from: $0, toolName: toolName) }
        let resultText = nonEmpty(parsedText) ?? preview

        return ToolCallResultDisplay(
            title: String(localized: "Result"),
            text: resultText,
            isMonospaced: isTerminalTool(toolName) || resultText.contains("\n") || parsedText != nil
        )
    }

    private static func readableResultText(from value: JSONValue, toolName: String?) -> String? {
        switch value {
        case .string(let value):
            return nonEmpty(normalizedDisplayString(value))
        case .number, .bool:
            return value.inlineDisplayText
        case .object(let object):
            if isTerminalTool(toolName),
               let terminalText = terminalEnvelopeText(from: object, toolName: toolName) {
                return terminalText
            }

            if let commonText = commonEnvelopeText(
                from: object,
                toolName: toolName,
                includeObjectFallback: false
            ) {
                return commonText
            }

            return terminalEnvelopeText(from: object, toolName: toolName)
                ?? commonEnvelopeText(from: object, toolName: toolName)
        case .array:
            return value.toolDisplayText
        case .null:
            return nil
        }
    }

    private static func terminalEnvelopeText(from object: [String: JSONValue], toolName: String?) -> String? {
        let terminalKeys: Set<String> = ["output", "stdout", "stderr", "exit_code", "exitCode", "error"]
        guard isTerminalTool(toolName) || object.keys.contains(where: terminalKeys.contains) else {
            return nil
        }

        var sections: [String] = []

        if let output = firstNonEmptyString(for: ["output", "stdout"], in: object) {
            sections.append(output)
        }

        if let stderr = nonEmptyString(from: object["stderr"]) {
            sections.append(stderr)
        }

        if let error = errorText(from: object["error"]) {
            sections.append(String(localized: "Error: \(error)"))
        }

        if let exitCode = exitCode(from: object["exit_code"] ?? object["exitCode"]),
           exitCode != 0 || sections.isEmpty {
            sections.append(String(localized: "Exit code: \(exitCode)"))
        }

        return nonEmpty(sections.joined(separator: "\n"))
    }

    private static func commonEnvelopeText(
        from object: [String: JSONValue],
        toolName: String?,
        includeObjectFallback: Bool = true
    ) -> String? {
        let preferredKeys = [
            "result",
            "results",
            "preview",
            "content",
            "text",
            "message",
            "summary",
            "data",
            "items"
        ]

        for key in preferredKeys {
            guard let value = object[key],
                  let text = readableEnvelopeValue(value, toolName: toolName)
            else {
                continue
            }
            return text
        }

        if let error = errorText(from: object["error"]) {
            return String(localized: "Error: \(error)")
        }

        guard includeObjectFallback else { return nil }

        return object.isEmpty ? nil : JSONValue.object(object).toolDisplayText
    }

    private static func readableEnvelopeValue(_ value: JSONValue, toolName: String?) -> String? {
        switch value {
        case .string(let string):
            let normalized = normalizedDisplayString(string)
            if let parsed = parsedJSONValue(from: normalized),
               let text = readableResultText(from: parsed, toolName: toolName) {
                return text
            }
            return nonEmpty(normalized)
        case .number, .bool:
            return value.inlineDisplayText
        case .object:
            return readableResultText(from: value, toolName: toolName) ?? value.toolDisplayText
        case .array:
            return readableTextArrayValue(value) ?? value.toolDisplayText
        case .null:
            return nil
        }
    }

    private static func readableTextArrayValue(_ value: JSONValue) -> String? {
        guard case .array(let values) = value else { return nil }

        let textValues = values.compactMap { item -> String? in
            guard case .object(let object) = item else { return nil }
            return nonEmptyString(from: object["text"])
                ?? nonEmptyString(from: object["content"])
                ?? nonEmptyString(from: object["message"])
        }

        guard textValues.count == values.count, !textValues.isEmpty else {
            return nil
        }

        return nonEmpty(textValues.joined(separator: "\n"))
    }

    private static func firstNonEmptyString(for keys: [String], in object: [String: JSONValue]) -> String? {
        for key in keys {
            if let value = nonEmptyString(from: object[key]) {
                return value
            }
        }
        return nil
    }

    private static func nonEmptyString(from value: JSONValue?) -> String? {
        guard let value else { return nil }

        switch value {
        case .string(let value):
            return nonEmpty(normalizedDisplayString(value))
        case .number, .bool:
            return value.inlineDisplayText
        case .object, .array:
            return nonEmpty(value.toolDisplayText)
        case .null:
            return nil
        }
    }

    private static func errorText(from value: JSONValue?) -> String? {
        guard let value else { return nil }

        switch value {
        case .null:
            return nil
        default:
            return nonEmptyString(from: value)
        }
    }

    private static func exitCode(from value: JSONValue?) -> Int? {
        guard let value else { return nil }

        switch value {
        case .number(let value):
            guard value.isFinite else { return nil }
            // Int(exactly:) so an out-of-range exit code from tool output
            // becomes nil instead of trapping (#62).
            return Int(exactly: value.rounded(.towardZero))
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool, .object, .array, .null:
            return nil
        }
    }

    private static func parsedJSONValue(from text: String) -> JSONValue? {
        let candidates = jsonCandidates(from: text)

        for candidate in candidates {
            guard let value = decodedJSONValue(from: candidate) else { continue }
            return unwrappedNestedJSONValue(value)
        }

        return nil
    }

    private static func jsonCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]

        if trimmed.contains(#"\""#) {
            let normalizedQuotes = trimmed.replacingOccurrences(of: #"\""#, with: #"""#)
            if normalizedQuotes != trimmed {
                candidates.append(normalizedQuotes)
            }
        }

        if let data = trimmed.data(using: .utf8),
           let decodedString = try? JSONDecoder().decode(String.self, from: data) {
            candidates.append(decodedString)
        }

        return candidates
    }

    private static func decodedJSONValue(from text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func unwrappedNestedJSONValue(_ value: JSONValue) -> JSONValue {
        var current = value

        for _ in 0..<3 {
            guard case .string(let string) = current,
                  let parsed = decodedJSONValue(from: string.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return current
            }
            current = parsed
        }

        return current
    }

    private static func isTerminalTool(_ toolName: String?) -> Bool {
        let name = toolName?.lowercased() ?? ""
        return ["terminal", "shell", "bash", "zsh", "command", "exec"].contains { name.contains($0) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    fileprivate static func normalizedDisplayString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\\r\\n"#, with: "\n")
            .replacingOccurrences(of: #"\r\n"#, with: "\n")
            .replacingOccurrences(of: #"\\n"#, with: "\n")
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\\t"#, with: "\t")
            .replacingOccurrences(of: #"\t"#, with: "\t")
    }
}

private extension JSONValue {
    var inlineDisplayText: String? {
        switch self {
        case .string(let value):
            let text = ToolCallDisplayFormatter.normalizedDisplayString(value)
            return text.contains("\n") ? nil : text
        case .number(let value):
            return value.formatted()
        case .bool(let value):
            return value ? "true" : "false"
        case .object(let value):
            return value.isEmpty ? "{}" : nil
        case .array(let value):
            return value.isEmpty ? "[]" : nil
        case .null:
            return "null"
        }
    }

    var toolDisplayText: String {
        multilineDisplayText(indentation: 0)
    }

    private func multilineDisplayText(indentation: Int) -> String {
        let indent = String(repeating: " ", count: indentation)

        if let inlineDisplayText {
            return "\(indent)\(inlineDisplayText)"
        }

        switch self {
        case .object(let value):
            return value
                .sorted { $0.key < $1.key }
                .map { key, value in
                    if let inline = value.inlineDisplayText {
                        return "\(indent)\(key): \(inline)"
                    }

                    return "\(indent)\(key):\n\(value.multilineDisplayText(indentation: indentation + 2))"
                }
                .joined(separator: "\n")
        case .array(let value):
            return value
                .map { item in
                    if let inline = item.inlineDisplayText {
                        return "\(indent)- \(inline)"
                    }

                    return "\(indent)-\n\(item.multilineDisplayText(indentation: indentation + 2))"
                }
                .joined(separator: "\n")
        case .string(let value):
            let text = ToolCallDisplayFormatter.normalizedDisplayString(value)
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "\(indent)\($0)" }
                .joined(separator: "\n")
        case .number, .bool, .null:
            return "\(indent)\(inlineDisplayText ?? "")"
        }
    }
}
