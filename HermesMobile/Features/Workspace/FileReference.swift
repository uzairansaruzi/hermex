import Foundation

/// A link to a file in the session workspace, the way an agent writes it in chat: a
/// `file:` URL, an absolute path under the workspace, or a `./`, `../`, or `~/` path,
/// each with an optional `:line[:column]` suffix or `#L12[C3]` fragment.
///
/// `path` is workspace-relative and `/`-joined, the same identity the file tree and
/// `/api/file` use. Bare relative paths (`src/main.swift`) are not file links: a
/// relative web URL looks the same, so they keep the ordinary link behaviour.
struct FileReference: Hashable, Identifiable {
    let path: String
    let line: Int?
    let column: Int?

    var id: String { label }

    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The reference as it reads in chat: `ChatView.swift:12:3`.
    var label: String {
        guard let line else { return name }
        guard let column else { return "\(name):\(line)" }
        return "\(name):\(line):\(column)"
    }

    /// Parses a Markdown link destination against the session's workspace root. Nil when
    /// the destination is not a file link, the workspace root is unknown, or the path
    /// resolves outside the workspace (including `..` traversal).
    static func parse(_ destination: String, workspaceRoot: String?) -> FileReference? {
        guard let rootComponents = pathComponents(ofAbsolutePath: workspaceRoot ?? ""),
              !rootComponents.isEmpty else { return nil }

        var normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("<"), normalized.hasSuffix(">"), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        guard let target = fileTarget(of: normalized) else { return nil }

        let position = splitPosition(path: target.path, fragment: target.fragment)
        guard let absolute = absolutePath(for: position.path, rootComponents: rootComponents),
              absolute.count > rootComponents.count,
              absolute.starts(with: rootComponents) else { return nil }

        return FileReference(
            path: absolute.dropFirst(rootComponents.count).joined(separator: "/"),
            line: position.line,
            column: position.column
        )
    }

    // MARK: - Parsing

    private struct Target {
        let path: String
        let fragment: String
    }

    /// The path and fragment of a destination that could name a file; nil for everything
    /// with another scheme or without an accepted prefix.
    private static func fileTarget(of destination: String) -> Target? {
        if destination.lowercased().hasPrefix("file:") {
            guard let url = URL(string: destination), url.scheme?.lowercased() == "file" else { return nil }
            let path = url.path(percentEncoded: false)
            guard path.hasPrefix("/") else { return nil }
            return Target(path: path, fragment: url.fragment(percentEncoded: false) ?? "")
        }

        let acceptedPrefixes = ["/", "./", "../", "~/"]
        guard acceptedPrefixes.contains(where: destination.hasPrefix) else { return nil }

        var path = destination
        var fragment = ""
        if let hashIndex = path.firstIndex(of: "#") {
            fragment = String(path[path.index(after: hashIndex)...])
            path = String(path[..<hashIndex])
        }
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }
        return Target(
            path: path.removingPercentEncoding ?? path,
            fragment: fragment.removingPercentEncoding ?? fragment
        )
    }

    private struct Position {
        let path: String
        let line: Int?
        let column: Int?
    }

    /// Strips `:line[:column]` from the path, or reads `L12[C3]` from the fragment when the
    /// path carries no suffix. Zero and negative positions are dropped.
    private static func splitPosition(path: String, fragment: String) -> Position {
        if let match = path.firstMatch(of: /:(\d+)(?::(\d+))?$/) {
            return Position(
                path: String(path[..<match.range.lowerBound]),
                line: positiveInt(match.1),
                column: match.2.flatMap(positiveInt)
            )
        }
        if let match = fragment.firstMatch(of: /^L(\d+)(?:C(\d+))?$/.ignoresCase()) {
            return Position(path: path, line: positiveInt(match.1), column: match.2.flatMap(positiveInt))
        }
        return Position(path: path, line: nil, column: nil)
    }

    private static func positiveInt(_ digits: Substring) -> Int? {
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// Resolves `path` to normalized absolute components. `~/` expands to the home directory
    /// the workspace root sits in (`/Users/<name>` or `/home/<name>`); `./` and `../` are
    /// taken from the workspace root.
    private static func absolutePath(for path: String, rootComponents: [String]) -> [String]? {
        if path.hasPrefix("/") {
            return pathComponents(ofAbsolutePath: path)
        }
        if path.hasPrefix("~/") {
            guard rootComponents.count >= 2, ["Users", "home"].contains(rootComponents[0]) else { return nil }
            return normalize(Array(rootComponents.prefix(2)) + path.dropFirst(2).split(separator: "/").map(String.init))
        }
        return normalize(rootComponents + path.split(separator: "/").map(String.init))
    }

    private static func pathComponents(ofAbsolutePath path: String) -> [String]? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return normalize(trimmed.split(separator: "/").map(String.init))
    }

    /// Collapses `.` and `..`; nil when `..` would climb above the filesystem root.
    private static func normalize(_ components: [String]) -> [String]? {
        var result: [String] = []
        for component in components {
            switch component {
            case "", ".":
                continue
            case "..":
                guard result.popLast() != nil else { return nil }
            default:
                result.append(component)
            }
        }
        return result
    }
}
