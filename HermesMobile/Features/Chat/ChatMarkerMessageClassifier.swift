import Foundation

enum ChatMarkerMessageKind: Equatable {
    case contextCompaction
    case preservedTaskList
    case compressionReference

    var title: String {
        switch self {
        case .contextCompaction, .compressionReference:
            return String(localized: "Context compaction")
        case .preservedTaskList:
            return String(localized: "Preserved task list")
        }
    }
}

enum ChatMarkerMessageClassifier {
    private static let preservedTaskListPrefix = "[your active task list was preserved across context compression]"
    private static let contextCompactionPrefixes = ["[context compaction", "context compaction"]

    static func classify(_ message: ChatMessage) -> ChatMarkerMessageKind? {
        guard let role = message.role, role != "tool" else { return nil }

        let text = trimmedContent(of: message)

        if role == "user", hasCaseInsensitivePrefix(text, preservedTaskListPrefix) {
            return .preservedTaskList
        }

        if isContextCompactionText(text) {
            return .contextCompaction
        }

        return nil
    }

    static func isContextCompactionText(_ text: String?) -> Bool {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return contextCompactionPrefixes.contains { hasCaseInsensitivePrefix(trimmed, $0) }
    }

    static func cardBody(for kind: ChatMarkerMessageKind, content: String?) -> String {
        let text = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard kind == .preservedTaskList,
              let markerRange = text.range(
                of: preservedTaskListPrefix,
                options: [.caseInsensitive, .anchored]
              )
        else {
            return text
        }

        return String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedContent(of message: ChatMessage) -> String {
        (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasCaseInsensitivePrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
}
