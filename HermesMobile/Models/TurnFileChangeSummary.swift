import Foundation

// In-chat "N files changed" recap (issue #316, Workspace git Slice D).
//
// The recap's file list is derived from an assistant turn's *tool-call metadata* (which
// file-mutating tools ran, and on which paths) rather than a `git/status` snapshot — a
// snapshot can't isolate a single turn's edits from accumulated uncommitted/external
// changes. Each derived path is then joined to `git/status` for the `+N −M` line counts
// and the status chip. No new endpoint; read-only over data the chat already has.
//
// Mirrors the webui reference aggregation in `.codex-tmp/hermes-webui/static/workspace.js`
// (mutation tool-name set, path-arg keys, path normalization, ignore filter).

/// A single file changed during one assistant turn.
struct TurnFileChange: Identifiable, Equatable {
    /// Normalized, workspace-relative (or absolute, if the tool reported one) path.
    let path: String
    /// Added lines, from the matched `git/status` entry (`0` when there is no net change).
    let additions: Int
    /// Removed lines, from the matched `git/status` entry (`0` when there is no net change).
    let deletions: Int
    /// What the tool did to the file (drives the streaming action label / fallback chip).
    let action: Action
    /// Status chip kind — the matched `git/status` kind when available, else derived
    /// from `action`.
    let changeKind: GitFile.ChangeKind
    /// The matched `git/status` file, when one exists. `nil` for a tool-touched path with
    /// no net git change (the row then shows `+0 −0` and is not openable in the diff sheet).
    let gitFile: GitFile?

    var id: String { path }

    /// Last path component, e.g. `ContentView.swift`.
    var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    enum Action: Equatable {
        case edited
        case added
        case deleted
        case renamed

        /// Fallback chip kind when the path didn't match a `git/status` entry.
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

/// Aggregated per-turn file-change recap. An empty `changes` array means "show nothing"
/// (a turn that changed no files, or a non-git workspace).
struct TurnFileChangeSummary: Equatable {
    let changes: [TurnFileChange]

    static let empty = TurnFileChangeSummary(changes: [])

    var fileCount: Int { changes.count }
    var hasChanges: Bool { !changes.isEmpty }
    var totalAdditions: Int { changes.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { changes.reduce(0) { $0 + $1.deletions } }

    /// `git/status` files backing the changes, for opening the per-turn diff sheet.
    var diffFiles: [GitFile] { changes.compactMap(\.gitFile) }

    /// Compact composer-capsule title, e.g. "1 change" / "3 changes".
    var capsuleTitle: String {
        fileCount == 1
            ? String(localized: "1 change")
            : String(localized: "\(fileCount) changes")
    }

    /// Sheet/header title, e.g. "1 file changed" / "3 files changed".
    var filesChangedTitle: String {
        fileCount == 1
            ? String(localized: "1 file changed")
            : String(localized: "\(fileCount) files changed")
    }
}

/// Pure aggregation of a turn's file changes from tool-call metadata, joined to git status.
/// Stateless and deterministic so it can be unit-tested in isolation.
enum TurnFileChangeAggregator {
    /// Build the recap for one assistant turn.
    /// - Parameters:
    ///   - toolCalls: the turn's tool calls (live during streaming, or the archived group).
    ///   - status: the latest `git/status`, joined for line counts and chips (`nil` ok).
    ///   - rowPath: maps a normalized tool path to the path status rows use, as
    ///     `GitDataClient.rowPath(forToolPath:)` does; webui's are the same.
    static func summarize(toolCalls: [ToolCall], status: GitStatus?,
                          rowPath: (String) -> String = { $0 }) -> TurnFileChangeSummary {
        var orderedPaths: [String] = []
        var actionByPath: [String: TurnFileChange.Action] = [:]

        for toolCall in toolCalls {
            for candidate in candidates(from: toolCall) {
                guard let path = normalize(candidate.path).map(rowPath) else { continue }

                if let existing = actionByPath[path] {
                    // A path edited and (re)created in the same turn reads better as the
                    // stronger action; never let a later plain "edit" downgrade it.
                    if existing == .edited, candidate.action != .edited {
                        actionByPath[path] = candidate.action
                    }
                } else {
                    orderedPaths.append(path)
                    actionByPath[path] = candidate.action
                }
            }
        }

        let trackedFiles = status?.trackedFiles ?? []
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

        return TurnFileChangeSummary(changes: changes)
    }

    // MARK: - Tool-call metadata extraction

    /// File-mutating tools whose path arguments attribute a per-turn change. Tools outside
    /// this set (reads, searches, shell, …) are intentionally ignored — a path they touch
    /// is not per-turn attributed (it still shows in the global status sheet).
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

    /// Ordered (rawPath, action) candidates extracted from one tool call's arguments.
    private static func candidates(from toolCall: ToolCall) -> [(path: String, action: TurnFileChange.Action)] {
        guard let name = normalizedToolName(toolCall.name),
              let action = action(forToolNamed: name),
              let args = toolCall.args
        else {
            return []
        }

        // A rename/move yields a single file at its destination; the source path no longer
        // exists in `git/status`, so don't emit a phantom row for it.
        if action == .renamed {
            if let destination = firstString(in: args, keys: ["destination", "path", "file_path", "filename"]) {
                return [(path: destination, action: .renamed)]
            }
            return []
        }

        var results: [(path: String, action: TurnFileChange.Action)] = []

        // `source`/`destination` are rename semantics and are consumed by the early-return
        // rename branch above; only the plain path keys apply to edit/add/delete tools.
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

    /// Only string args are usable as paths (numbers/bools/objects are not file paths).
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Path normalization & ignore filter

    private static let trimCharacters = CharacterSet(charactersIn: "`\"'<>()[]{}")

    /// Path component names that mark generated/vendored trees we never attribute.
    private static let ignoredComponents: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".venv", "venv",
        "__pycache__", "dist", "build", ".next", ".cache"
    ]

    /// Normalize a raw tool path to a comparable workspace path, or `nil` to drop it.
    /// Strips wrapping quotes/brackets, drops `~/` and `./` prefixes, rejects URLs and
    /// over-long paths, and filters generated/vendored trees.
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

    // MARK: - git/status join

    /// Find the `git/status` entry for a tool path, tolerating absolute-vs-relative
    /// references to the same repo file.
    private static func matchingFile(for path: String, in files: [GitFile]) -> GitFile? {
        if let exact = files.first(where: { displayPath($0) == path }) {
            return exact
        }
        return files.first { representsSameFile(displayPath($0), path) }
    }

    private static func displayPath(_ file: GitFile) -> String {
        normalize(file.displayPath) ?? file.displayPath
    }

    /// True when two normalized paths point at the same file — equal, or one is the
    /// absolute form of the other (suffix match on a `/`-boundary). The suffix checks are
    /// gated on the longer path being absolute so two distinct *relative* paths that merely
    /// share a trailing component (e.g. `other/App.swift` vs `some/other/App.swift`) never
    /// falsely match.
    private static func representsSameFile(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        if lhs.hasPrefix("/"), lhs.hasSuffix("/" + rhs) { return true }
        if rhs.hasPrefix("/"), rhs.hasSuffix("/" + lhs) { return true }
        return false
    }
}
