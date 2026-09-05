import Foundation

/// One entry in the workspace tree. `path` is relative to the workspace root and joined with
/// "/", which makes it the stable identity for rows, selection, and expansion state.
struct FileTreeNode: Identifiable, Hashable {
    var id: String { path }

    let path: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let entry: WorkspaceEntry
    /// Lowercased path components; search matches these exactly, by prefix, boundary, or substring.
    let searchSegments: [String]
    /// camelCase-split words from every component; search also matches these fuzzily.
    let searchWords: [String]

    /// Returns nil for an entry that carries neither a name nor a path.
    init?(entry: WorkspaceEntry, parentPath: String) {
        let trimmedName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPath = entry.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let path: String
        if !trimmedPath.isEmpty, trimmedPath != FileTree.rootPath {
            path = trimmedPath
        } else if !trimmedName.isEmpty {
            path = parentPath == FileTree.rootPath ? trimmedName : "\(parentPath)/\(trimmedName)"
        } else {
            return nil
        }

        self.path = path
        name = trimmedName.isEmpty ? String(path.split(separator: "/").last ?? Substring(path)) : trimmedName
        isDirectory = entry.isBrowsableDirectory
        isSymlink = entry.type == "symlink"
        self.entry = entry

        var segments: [String] = []
        var words: [String] = []
        for component in path.split(separator: "/") where !component.isEmpty {
            segments.append(component.lowercased())
            words.append(contentsOf: FileTreeSearch.splitWords(String(component)))
        }
        searchSegments = segments
        searchWords = words
    }
}

/// A node placed in the flattened list, with the depth that drives its indent.
struct VisibleFileTreeNode: Identifiable, Equatable {
    var id: String { node.path }

    let node: FileTreeNode
    let depth: Int
}

/// The lazily loaded workspace tree. `children` holds the sorted entries of every directory
/// fetched so far, keyed by directory path (`rootPath` for the workspace root); a missing key
/// means that directory has not been listed yet.
struct FileTree: Equatable {
    static let rootPath = "."

    private(set) var children: [String: [FileTreeNode]] = [:]

    var isRootLoaded: Bool { children[Self.rootPath] != nil }
    var rootNodes: [FileTreeNode] { children[Self.rootPath] ?? [] }

    func children(of directory: String) -> [FileTreeNode]? {
        children[directory]
    }

    func isLoaded(_ directory: String) -> Bool {
        children[directory] != nil
    }

    func node(at path: String) -> FileTreeNode? {
        children[Self.parentPath(of: path)]?.first { $0.path == path }
    }

    /// Replaces a directory's listing and forgets listings of subdirectories that no longer exist.
    mutating func setChildren(_ entries: [WorkspaceEntry], of directory: String) {
        let nodes = Self.sorted(entries.compactMap { FileTreeNode(entry: $0, parentPath: directory) })
        children[directory] = nodes

        let survivingDirectories = Set(nodes.filter(\.isDirectory).map(\.path))
        let prefix = directory == Self.rootPath ? "" : directory + "/"
        for key in children.keys where key != directory && key.hasPrefix(prefix) {
            let remainder = key.dropFirst(prefix.count)
            let firstComponent = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? remainder
            if !survivingDirectories.contains(prefix + firstComponent) {
                children[key] = nil
            }
        }
    }

    mutating func removeAll() {
        children.removeAll()
    }

    /// Directories first, then Finder-style natural order (case-insensitive, numeric-aware).
    static func sorted(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return rootPath }
        return String(path[..<slash])
    }

    /// Every directory between the root and `path`, top-down, excluding the root and `path` itself.
    static func ancestorPaths(of path: String) -> [String] {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts[..<$0].joined(separator: "/") }
    }

    /// The top-level directories that open on first visit: every one except hidden dot-folders.
    static func defaultExpandedPaths(in rootNodes: [FileTreeNode]) -> Set<String> {
        Set(rootNodes.filter { $0.isDirectory && !$0.name.hasPrefix(".") }.map(\.path))
    }

    /// Flattens the tree for display. Without a query, a directory's children appear only when
    /// it is expanded. With a query, every loaded directory is traversed and a node stays visible
    /// when it or any descendant matches, so results keep their ancestors for context.
    func visibleNodes(expanded: Set<String>, searchQuery: String = "") -> [VisibleFileTreeNode] {
        let tokens = FileTreeSearch.tokens(from: searchQuery)
        var output: [VisibleFileTreeNode] = []
        for node in rootNodes {
            append(node, depth: 0, expanded: expanded, tokens: tokens, into: &output)
        }
        return output
    }

    @discardableResult
    private func append(
        _ node: FileTreeNode,
        depth: Int,
        expanded: Set<String>,
        tokens: [String],
        into output: inout [VisibleFileTreeNode]
    ) -> Bool {
        let isSearching = !tokens.isEmpty
        let matches = isSearching && FileTreeSearch.matches(node, tokens: tokens)
        var descendantMatches = false
        var childOutput: [VisibleFileTreeNode] = []

        if node.isDirectory, expanded.contains(node.path) || isSearching, let children = children[node.path] {
            for child in children where append(child, depth: depth + 1, expanded: expanded, tokens: tokens, into: &childOutput) {
                descendantMatches = true
            }
        }

        guard !isSearching || matches || descendantMatches else { return false }

        output.append(VisibleFileTreeNode(node: node, depth: depth))
        output.append(contentsOf: childOutput)
        return matches || descendantMatches
    }
}

/// Tokenized, tiered matching for the tree search. Scores are lower-is-better; a node matches
/// when every query token matches one of its path segments, or fuzzily one of its words.
enum FileTreeSearch {
    static let boundaryMarkers = ["/", "-", "_", "."]

    /// Lowercased query split on whitespace and path punctuation.
    static func tokens(from query: String) -> [String] {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split { $0.isWhitespace || "/\\._-".contains($0) }
            .map(String.init)
    }

    /// Splits `ChatStreamCoordinator.swift` into `chat stream coordinator swift`, keeping
    /// acronym runs like `HTTPServer` as `http server`.
    static func splitWords(_ value: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(value)

        for index in characters.indices {
            let character = characters[index]
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }

            if !current.isEmpty, character.isUppercase {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let lowerToUpper = previous.isLowercase || previous.isNumber
                let acronymEnd = previous.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || acronymEnd {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }

        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// Tiers: exact 0, prefix 2, boundary 4, substring 6, then fuzzy subsequence at 100 when
    /// enabled. Each tier adds position and length penalties. Expects lowercased inputs.
    static func score(value: String, query: String, fuzzy: Bool) -> Int? {
        guard !value.isEmpty, !query.isEmpty else { return nil }
        if value == query { return 0 }

        let lengthPenalty = min(64, max(0, value.count - query.count))
        if value.hasPrefix(query) { return 2 + lengthPenalty }

        let characters = Array(value)
        let boundaryIndex = boundaryMarkers
            .compactMap { marker -> Int? in
                guard let range = value.range(of: marker + query) else { return nil }
                return value.distance(from: value.startIndex, to: range.lowerBound) + marker.count
            }
            .min()
        if let boundaryIndex { return 4 + boundaryIndex * 2 + lengthPenalty }

        if let range = value.range(of: query) {
            return 6 + value.distance(from: value.startIndex, to: range.lowerBound) * 2 + lengthPenalty
        }

        guard fuzzy, let subsequence = subsequenceScore(Array(query), in: characters) else { return nil }
        return 100 + subsequence
    }

    static func matches(_ node: FileTreeNode, tokens: [String]) -> Bool {
        tokens.allSatisfy { token in
            node.searchSegments.contains { score(value: $0, query: token, fuzzy: false) != nil }
                || node.searchWords.contains { score(value: $0, query: token, fuzzy: true) != nil }
        }
    }

    private static func subsequenceScore(_ query: [Character], in value: [Character]) -> Int? {
        var queryIndex = 0
        var firstMatch = -1
        var previousMatch = -1
        var gapPenalty = 0

        for (index, character) in value.enumerated() where character == query[queryIndex] {
            if firstMatch == -1 { firstMatch = index }
            if previousMatch != -1 { gapPenalty += index - previousMatch - 1 }
            previousMatch = index
            queryIndex += 1

            if queryIndex == query.count {
                let spanPenalty = index - firstMatch + 1 - query.count
                let lengthPenalty = min(64, value.count - query.count)
                return firstMatch * 2 + gapPenalty * 3 + spanPenalty + lengthPenalty
            }
        }

        return nil
    }
}
