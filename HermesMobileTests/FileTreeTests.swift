import XCTest
@testable import HermesMobile

/// Pure tree behaviour for the workspace file browser: ordering, lazy structure, search.
final class FileTreeTests: XCTestCase {

    private func dir(_ name: String, path: String? = nil) -> WorkspaceEntry {
        WorkspaceEntry(name: name, path: path ?? name, type: "dir", isDirectory: true)
    }

    private func file(_ name: String, path: String? = nil) -> WorkspaceEntry {
        WorkspaceEntry(name: name, path: path ?? name, type: "file", size: 1, isDirectory: false)
    }

    /// src/{Chat/{ChatView.swift}, Util/{Math.swift}}, README.md — every directory listed.
    private func sampleTree() -> FileTree {
        var tree = FileTree()
        tree.setChildren([file("README.md"), dir("src")], of: FileTree.rootPath)
        tree.setChildren([dir("Util", path: "src/Util"), dir("Chat", path: "src/Chat")], of: "src")
        tree.setChildren([file("ChatView.swift", path: "src/Chat/ChatView.swift")], of: "src/Chat")
        tree.setChildren([file("Math.swift", path: "src/Util/Math.swift")], of: "src/Util")
        return tree
    }

    private func paths(_ nodes: [VisibleFileTreeNode]) -> [String] {
        nodes.map(\.node.path)
    }

    // MARK: - Structure

    func testSortsDirectoriesFirstThenNaturalOrder() {
        var tree = FileTree()
        tree.setChildren([file("file10.txt"), file("file2.txt"), dir("Zeta"), file("Beta.txt"), dir("alpha")], of: FileTree.rootPath)

        XCTAssertEqual(tree.rootNodes.map(\.name), ["alpha", "Zeta", "Beta.txt", "file2.txt", "file10.txt"])
    }

    func testNodePathFallsBackToParentAndNameAndSkipsBlankEntries() {
        var tree = FileTree()
        tree.setChildren([
            WorkspaceEntry(name: "notes.txt", path: nil),
            WorkspaceEntry(name: nil, path: nil)
        ], of: "docs")

        XCTAssertEqual(tree.children(of: "docs")?.map(\.path), ["docs/notes.txt"])
        XCTAssertEqual(tree.node(at: "docs/notes.txt")?.name, "notes.txt")
        XCTAssertEqual(tree.node(at: "docs/notes.txt")?.entry.path, "docs/notes.txt", "The preview reads the entry's path")
    }

    func testSymlinkKeepsDirectoryFlagFromServer() {
        var tree = FileTree()
        tree.setChildren([
            WorkspaceEntry(name: "AGENTS.md", path: "AGENTS.md", type: "symlink", isDirectory: false),
            WorkspaceEntry(name: "shared", path: "shared", type: "symlink", isDirectory: true)
        ], of: FileTree.rootPath)

        let nodes = tree.rootNodes
        XCTAssertEqual(nodes.map(\.path), ["shared", "AGENTS.md"])
        XCTAssertTrue(nodes[0].isDirectory)
        XCTAssertTrue(nodes[0].isSymlink)
        XCTAssertFalse(nodes[1].isDirectory)
        XCTAssertTrue(nodes[1].isSymlink)
    }

    func testReloadingADirectoryForgetsListingsOfRemovedSubdirectories() {
        var tree = sampleTree()

        tree.setChildren([dir("Chat", path: "src/Chat")], of: "src")

        XCTAssertTrue(tree.isLoaded("src/Chat"))
        XCTAssertFalse(tree.isLoaded("src/Util"))
    }

    func testAncestorAndParentPaths() {
        XCTAssertEqual(FileTree.ancestorPaths(of: "a/b/c.txt"), ["a", "a/b"])
        XCTAssertEqual(FileTree.ancestorPaths(of: "top.txt"), [])
        XCTAssertEqual(FileTree.parentPath(of: "a/b/c.txt"), "a/b")
        XCTAssertEqual(FileTree.parentPath(of: "top.txt"), FileTree.rootPath)
    }

    func testDefaultExpansionOpensTopLevelFoldersExceptHiddenOnes() {
        var tree = FileTree()
        tree.setChildren([dir(".git"), dir("src"), dir("docs"), file("README.md")], of: FileTree.rootPath)

        XCTAssertEqual(FileTree.defaultExpandedPaths(in: tree.rootNodes), ["src", "docs"])
    }

    // MARK: - Flattening

    func testFlattenShowsChildrenOnlyOfExpandedDirectories() {
        let tree = sampleTree()

        XCTAssertEqual(paths(tree.visibleNodes(expanded: [])), ["src", "README.md"])
        XCTAssertEqual(paths(tree.visibleNodes(expanded: ["src"])), ["src", "src/Chat", "src/Util", "README.md"])

        let deep = tree.visibleNodes(expanded: ["src", "src/Util"])
        XCTAssertEqual(paths(deep), ["src", "src/Chat", "src/Util", "src/Util/Math.swift", "README.md"])
        XCTAssertEqual(deep.map(\.depth), [0, 1, 1, 2, 0])
    }

    func testFlattenSkipsChildrenOfUnloadedDirectories() {
        var tree = FileTree()
        tree.setChildren([dir("src")], of: FileTree.rootPath)

        XCTAssertEqual(paths(tree.visibleNodes(expanded: ["src"])), ["src"])
    }

    // MARK: - Search

    func testSearchKeepsAncestorsOfMatchesAndTraversesCollapsedFolders() {
        let tree = sampleTree()

        let visible = tree.visibleNodes(expanded: [], searchQuery: "chatview")

        XCTAssertEqual(paths(visible), ["src", "src/Chat", "src/Chat/ChatView.swift"])
    }

    func testSearchRequiresEveryToken() {
        let tree = sampleTree()

        XCTAssertEqual(paths(tree.visibleNodes(expanded: [], searchQuery: "src chat")), ["src", "src/Chat", "src/Chat/ChatView.swift"])
        XCTAssertEqual(paths(tree.visibleNodes(expanded: [], searchQuery: "chat math")), [])
    }

    func testSearchMatchesCamelCaseWordsFuzzily() {
        let tree = sampleTree()

        XCTAssertEqual(paths(tree.visibleNodes(expanded: [], searchQuery: "vew")), ["src", "src/Chat", "src/Chat/ChatView.swift"])
    }

    func testSearchShowsMatchingUnloadedDirectory() {
        var tree = FileTree()
        tree.setChildren([dir("Features"), dir("Networking")], of: FileTree.rootPath)

        XCTAssertEqual(paths(tree.visibleNodes(expanded: [], searchQuery: "feat")), ["Features"])
    }

    func testSplitWordsHandlesCamelCaseAcronymsAndPunctuation() {
        XCTAssertEqual(FileTreeSearch.splitWords("ChatStreamCoordinator.swift"), ["chat", "stream", "coordinator", "swift"])
        XCTAssertEqual(FileTreeSearch.splitWords("HTTPServer"), ["http", "server"])
        XCTAssertEqual(FileTreeSearch.splitWords("file_v2-final"), ["file", "v2", "final"])
    }

    func testTokensSplitOnWhitespaceAndPathPunctuation() {
        XCTAssertEqual(FileTreeSearch.tokens(from: "  Src/Chat_view.swift  "), ["src", "chat", "view", "swift"])
        XCTAssertEqual(FileTreeSearch.tokens(from: "   "), [])
    }

    func testScoreTiersRankExactBeforePrefixBoundaryAndSubstring() throws {
        let exact = try XCTUnwrap(FileTreeSearch.score(value: "chat", query: "chat", fuzzy: false))
        let prefix = try XCTUnwrap(FileTreeSearch.score(value: "chatview", query: "chat", fuzzy: false))
        let boundary = try XCTUnwrap(FileTreeSearch.score(value: "my-chat", query: "chat", fuzzy: false))
        let substring = try XCTUnwrap(FileTreeSearch.score(value: "myxchat", query: "chat", fuzzy: false))

        XCTAssertEqual(exact, 0)
        XCTAssertLessThan(exact, prefix)
        XCTAssertLessThan(prefix, boundary)
        XCTAssertLessThan(boundary, substring)
    }

    func testScoreFallsBackToSubsequenceOnlyWhenFuzzy() throws {
        XCTAssertNil(FileTreeSearch.score(value: "coordinator", query: "cdt", fuzzy: false))
        let fuzzy = try XCTUnwrap(FileTreeSearch.score(value: "coordinator", query: "cdt", fuzzy: true))
        XCTAssertGreaterThanOrEqual(fuzzy, 100)
        XCTAssertNil(FileTreeSearch.score(value: "coordinator", query: "xyz", fuzzy: true))
    }
}
