import Foundation

struct FileReference: Hashable, Identifiable {
    let path: String
    let line: Int?
    let column: Int?

    var id: String { label }

    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var label: String {
        guard let line else { return name }
        guard let column else { return "\(name):\(line)" }
        return "\(name):\(line):\(column)"
    }

    static func absoluteMediaPath(_ destination: String, workspaceRoot: String?, resolvesBarePaths: Bool = false) -> String? {
        var normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("<"), normalized.hasSuffix(">"), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        let bare = resolvesBarePaths && !normalized.contains(":") && !normalized.hasPrefix("#")
        guard let target = fileTarget(of: normalized) ?? (bare ? fileTarget(of: "./" + normalized) : nil) else { return nil }

        let rootComponents = pathComponents(ofAbsolutePath: workspaceRoot ?? "") ?? []
        guard target.path.hasPrefix("/") || !rootComponents.isEmpty else { return nil }
        guard let components = absolutePath(for: target.path, rootComponents: rootComponents),
              !components.isEmpty
        else { return nil }

        return "/" + components.joined(separator: "/")
    }

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

    private struct Target {
        let path: String
        let fragment: String
    }

    private static func fileTarget(of destination: String) -> Target? {
        if destination.lowercased().hasPrefix("sandbox:/") {
            return fileTarget(of: String(destination.dropFirst("sandbox:".count)))
        }
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

enum BinaryFilePreview: Equatable {
    case quickLook
    case unavailable

    init?(path: String) {
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        if Self.quickLookExtensions.contains(pathExtension) {
            self = .quickLook
        } else if Self.unavailableExtensions.contains(pathExtension) {
            self = .unavailable
        } else {
            return nil
        }
    }

    private static let quickLookExtensions: Set<String> = [
        "aiff", "avi", "doc", "docx", "flac", "key", "m4a", "mov", "mp3", "mp4", "numbers",
        "pages", "pdf", "ppt", "pptx", "rtf", "svg", "usdz", "wav", "xls", "xlsx"
    ]

    private static let unavailableExtensions: Set<String> = [
        "7z", "a", "bin", "bz2", "class", "db", "dmg", "dylib", "exe", "gz",
        "jar", "o", "pkg", "pyc", "rar", "sqlite", "tar", "tgz", "xz", "zip"
    ]
}
