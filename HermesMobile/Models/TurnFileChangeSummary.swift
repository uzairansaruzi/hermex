import Foundation

struct TurnFileChange: Identifiable, Equatable {
    let path: String
    let additions: Int
    let deletions: Int
    let action: Action
    let changeKind: GitFile.ChangeKind
    let gitFile: GitFile?

    var id: String { path }

    var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    enum Action: Equatable {
        case edited
        case added
        case deleted
        case renamed

        var changeKind: GitFile.ChangeKind {
            switch self {
            case .edited: return .modified
            case .added: return .added
            case .deleted: return .deleted
            case .renamed: return .renamed
            }
        }
    }
}

struct TurnFileChangeSummary: Equatable {
    let changes: [TurnFileChange]
    var scope: GitReviewScope?

    static let empty = TurnFileChangeSummary(changes: [])

    var fileCount: Int { changes.count }
    var hasChanges: Bool { !changes.isEmpty }
    var totalAdditions: Int { changes.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { changes.reduce(0) { $0 + $1.deletions } }

    var diffFiles: [GitFile] { changes.compactMap(\.gitFile) }
}

enum TurnFileChangeAggregator {
    static func summarize(toolCalls: [ToolCall], files: [GitFile], scope: GitReviewScope? = nil,
                          rowPath: (String) -> String = { $0 }) -> TurnFileChangeSummary {
        var orderedPaths: [String] = []
        var actionByPath: [String: TurnFileChange.Action] = [:]

        for toolCall in toolCalls {
            for candidate in candidates(from: toolCall) {
                guard let path = normalize(candidate.path).map(rowPath) else { continue }

                if let existing = actionByPath[path] {
                    if existing == .edited, candidate.action != .edited {
                        actionByPath[path] = candidate.action
                    }
                } else {
                    orderedPaths.append(path)
                    actionByPath[path] = candidate.action
                }
            }
        }

        let trackedFiles = files.filter { !$0.isIgnoredFile }
        let changes = orderedPaths.map { path -> TurnFileChange in
            let action = actionByPath[path] ?? .edited
            let match = matchingFile(for: path, in: trackedFiles)
            return TurnFileChange(
                path: path,
                additions: match?.additions ?? 0,
                deletions: match?.deletions ?? 0,
                action: action,
                changeKind: match?.changeKind ?? action.changeKind,
                gitFile: match
            )
        }

        return TurnFileChangeSummary(changes: changes, scope: scope)
    }

    private static func action(forToolNamed name: String) -> TurnFileChange.Action? {
        switch name {
        case "create_file":
            return .added
        case "remove_file", "delete_file", "mcp_filesystem_remove_file":
            return .deleted
        case "move_file", "rename_file", "mcp_filesystem_move_file":
            return .renamed
        case "write_file", "patch", "edit_file",
             "mcp_filesystem_write_file", "mcp_filesystem_edit_file":
            return .edited
        default:
            return nil
        }
    }

    private static func candidates(from toolCall: ToolCall) -> [(path: String, action: TurnFileChange.Action)] {
        guard let name = normalizedToolName(toolCall.name),
              let action = action(forToolNamed: name),
              let args = toolCall.args
        else {
            return []
        }

        if action == .renamed {
            if let destination = firstString(in: args, keys: ["destination", "path", "file_path", "filename"]) {
                return [(path: destination, action: .renamed)]
            }
            return []
        }

        var results: [(path: String, action: TurnFileChange.Action)] = []

        for key in ["path", "file_path", "filename"] {
            if let value = string(args[key]) {
                results.append((path: value, action: action))
            }
        }

        if case .array(let items)? = args["paths"] {
            for item in items {
                if let value = string(item) {
                    results.append((path: value, action: action))
                }
            }
        }

        if case .array(let edits)? = args["edits"] {
            for edit in edits {
                if case .object(let object) = edit, let value = string(object["path"]) {
                    results.append((path: value, action: action))
                }
            }
        }

        return results
    }

    private static func normalizedToolName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private static func firstString(in args: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = string(args[key]) {
                return value
            }
        }
        return nil
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let trimCharacters = CharacterSet(charactersIn: "`\"'<>()[]{}")

    private static let ignoredComponents: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".venv", "venv",
        "__pycache__", "dist", "build", ".next", ".cache"
    ]

    static func normalize(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        path = path.trimmingCharacters(in: trimCharacters)
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !path.isEmpty, path.count <= 240, !path.contains("://") else { return nil }

        if path.hasPrefix("~/") { path.removeFirst(2) }
        while path.hasPrefix("./") { path.removeFirst(2) }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !path.isEmpty, !isIgnored(path) else { return nil }
        return path
    }

    private static func isIgnored(_ path: String) -> Bool {
        path.split(separator: "/").contains { ignoredComponents.contains(String($0)) }
    }

    private static func matchingFile(for path: String, in files: [GitFile]) -> GitFile? {
        if let exact = files.first(where: { displayPath($0) == path }) {
            return exact
        }
        return files.first { representsSameFile(displayPath($0), path) }
    }

    private static func displayPath(_ file: GitFile) -> String {
        normalize(file.displayPath) ?? file.displayPath
    }

    private static func representsSameFile(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        if lhs.hasPrefix("/"), lhs.hasSuffix("/" + rhs) { return true }
        if rhs.hasPrefix("/"), rhs.hasSuffix("/" + lhs) { return true }
        return false
    }
}
