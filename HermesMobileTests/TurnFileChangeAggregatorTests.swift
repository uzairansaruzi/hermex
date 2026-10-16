import XCTest
@testable import HermesMobile

/// Aggregation logic for the in-chat "N files changed" recap (issue #316, Slice D).
/// Covers tool-path extraction, normalization, the ignore filter, rename handling,
/// `paths[]`/`edits[]` arrays, and the `git/status` join for counts + chips.
final class TurnFileChangeAggregatorTests: XCTestCase {

    private func tool(_ name: String, _ args: [String: JSONValue]) -> ToolCall {
        ToolCall(name: name, preview: nil, args: args)
    }

    private func status(_ json: String) throws -> GitStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try XCTUnwrap(try decoder.decode(GitStatusResponse.self, from: Data(json.utf8)).git)
    }

    // MARK: - Extraction & multi-file edits

    func testMultiFileEditsProduceOrderedEntries() throws {
        let gitStatus = try status("""
        {"git": {"is_git": true, "files": [
          {"path": "Sources/App.swift", "status": "M", "unstaged": true, "additions": 30, "deletions": 2},
          {"path": "README.md", "status": "M", "unstaged": true, "additions": 12, "deletions": 5}
        ]}}
        """)
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("write_file", ["path": .string("Sources/App.swift")]),
                tool("edit_file", ["file_path": .string("README.md")])
            ],
            status: gitStatus
        )

        XCTAssertEqual(summary.changes.map(\.path), ["Sources/App.swift", "README.md"])
        XCTAssertEqual(summary.changes.map(\.additions), [30, 12])
        XCTAssertEqual(summary.changes.map(\.deletions), [2, 5])
        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(summary.totalAdditions, 42)
        XCTAssertEqual(summary.totalDeletions, 7)
        XCTAssertTrue(summary.hasChanges)
        XCTAssertEqual(summary.changes.map(\.action), [.edited, .edited])
    }

    func testReadAndShellToolsAreIgnored() {
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("read_file", ["path": .string("Sources/App.swift")]),
                tool("terminal", ["command": .string("ls -la")]),
                tool("search_files", ["path": .string("Sources")])
            ],
            status: nil
        )

        XCTAssertFalse(summary.hasChanges)
        XCTAssertEqual(summary, .empty)
    }

    // MARK: - Renames

    func testRenameUsesDestinationAndDropsSource() {
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("rename_file", [
                    "source": .string("old/name.swift"),
                    "destination": .string("new/name.swift")
                ])
            ],
            status: nil
        )

        XCTAssertEqual(summary.changes.map(\.path), ["new/name.swift"])
        XCTAssertEqual(summary.changes.first?.action, .renamed)
        XCTAssertEqual(summary.changes.first?.changeKind, .renamed)
    }

    // MARK: - paths[] and edits[] arrays

    func testPathsArrayProducesOneEntryPerPath() {
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("write_file", ["paths": .array([.string("a.txt"), .string("b.txt")])])
            ],
            status: nil
        )
        XCTAssertEqual(summary.changes.map(\.path), ["a.txt", "b.txt"])
    }

    func testEditsArrayProducesOneEntryPerEditPath() {
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("patch", ["edits": .array([
                    .object(["path": .string("x/one.swift")]),
                    .object(["path": .string("x/two.swift")]),
                    .object(["start": .number(1)]) // no path → skipped
                ])])
            ],
            status: nil
        )
        XCTAssertEqual(summary.changes.map(\.path), ["x/one.swift", "x/two.swift"])
    }

    // MARK: - Normalization

    func testNormalizationStripsPrefixesQuotesAndBrackets() {
        XCTAssertEqual(TurnFileChangeAggregator.normalize("~/Sources/App.swift"), "Sources/App.swift")
        XCTAssertEqual(TurnFileChangeAggregator.normalize("./README.md"), "README.md")
        XCTAssertEqual(TurnFileChangeAggregator.normalize("././nested/file.swift"), "nested/file.swift")
        XCTAssertEqual(TurnFileChangeAggregator.normalize("\"quoted.swift\""), "quoted.swift")
        XCTAssertEqual(TurnFileChangeAggregator.normalize("`code.swift`"), "code.swift")
        XCTAssertEqual(TurnFileChangeAggregator.normalize("  spaced.swift  "), "spaced.swift")
        XCTAssertEqual(TurnFileChangeAggregator.normalize("/abs/path.swift"), "/abs/path.swift")
    }

    func testNormalizationRejectsURLsEmptyAndOverlongPaths() {
        XCTAssertNil(TurnFileChangeAggregator.normalize("https://example.com/x.swift"))
        XCTAssertNil(TurnFileChangeAggregator.normalize(""))
        XCTAssertNil(TurnFileChangeAggregator.normalize("   "))
        XCTAssertNil(TurnFileChangeAggregator.normalize(String(repeating: "a", count: 241)))
    }

    // MARK: - Ignore filter

    func testIgnoredTreesAreDropped() {
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("write_file", ["path": .string("node_modules/lib/index.js")]),
                tool("write_file", ["path": .string(".git/config")]),
                tool("write_file", ["path": .string("dist/bundle.js")]),
                tool("write_file", ["path": .string("build/output.o")]),
                tool("write_file", ["path": .string(".venv/lib/site.py")]),
                tool("write_file", ["path": .string("pkg/__pycache__/mod.pyc")]),
                tool("write_file", ["path": .string("src/keep.swift")])
            ],
            status: nil
        )

        XCTAssertEqual(summary.changes.map(\.path), ["src/keep.swift"])
    }

    // MARK: - git/status join

    func testJoinUsesStatusCountsAndChangeKind() throws {
        let gitStatus = try status("""
        {"git": {"is_git": true, "files": [
          {"path": "new.swift", "status": "A", "staged": true, "additions": 9, "deletions": 0},
          {"path": "gone.swift", "status": "D", "staged": true, "additions": 0, "deletions": 7}
        ]}}
        """)
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("create_file", ["path": .string("new.swift")]),
                tool("remove_file", ["path": .string("gone.swift")])
            ],
            status: gitStatus
        )

        let added = try XCTUnwrap(summary.changes.first { $0.path == "new.swift" })
        XCTAssertEqual(added.additions, 9)
        XCTAssertEqual(added.changeKind, .added)
        XCTAssertNotNil(added.gitFile)

        let deleted = try XCTUnwrap(summary.changes.first { $0.path == "gone.swift" })
        XCTAssertEqual(deleted.deletions, 7)
        XCTAssertEqual(deleted.changeKind, .deleted)
    }

    func testJoinMatchesAbsoluteToolPathToRelativeStatusEntry() throws {
        let gitStatus = try status("""
        {"git": {"is_git": true, "files": [
          {"path": "Sources/App.swift", "status": "M", "unstaged": true, "additions": 4, "deletions": 1}
        ]}}
        """)
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [tool("edit_file", ["path": .string("/Users/me/repo/Sources/App.swift")])],
            status: gitStatus
        )

        let change = try XCTUnwrap(summary.changes.first)
        XCTAssertEqual(change.additions, 4)
        XCTAssertEqual(change.deletions, 1)
        XCTAssertNotNil(change.gitFile)
    }

    func testJoinDoesNotMatchDistinctRelativePathsSharingASuffix() throws {
        // A tool edits a relative `other/App.swift`; git status separately modified a
        // *different* file `some/other/App.swift`. The shared trailing component must not
        // make the tool path inherit the other file's counts/chip (suffix match is gated
        // on the longer path being absolute).
        let gitStatus = try status("""
        {"git": {"is_git": true, "files": [
          {"path": "some/other/App.swift", "status": "M", "unstaged": true, "additions": 9, "deletions": 3}
        ]}}
        """)
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [tool("edit_file", ["path": .string("other/App.swift")])],
            status: gitStatus
        )

        let change = try XCTUnwrap(summary.changes.first)
        XCTAssertEqual(change.path, "other/App.swift")
        XCTAssertEqual(change.additions, 0)
        XCTAssertEqual(change.deletions, 0)
        XCTAssertNil(change.gitFile)
    }

    func testUnmatchedPathShowsZeroCountsAndToolActionChip() {
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [tool("write_file", ["path": .string("untouched.swift")])],
            status: nil
        )

        let change = summary.changes.first
        XCTAssertEqual(change?.additions, 0)
        XCTAssertEqual(change?.deletions, 0)
        XCTAssertEqual(change?.changeKind, .modified)
        XCTAssertNil(change?.gitFile)
        XCTAssertTrue(summary.diffFiles.isEmpty)
    }

    // MARK: - Consolidation

    func testSamePathEditedTwiceConsolidatesToOneEntry() {
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("write_file", ["path": .string("a.swift")]),
                tool("edit_file", ["path": .string("a.swift")])
            ],
            status: nil
        )
        XCTAssertEqual(summary.changes.count, 1)
        XCTAssertEqual(summary.changes.first?.path, "a.swift")
    }

    func testCreateThenEditPrefersAddedAction() {
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: [
                tool("create_file", ["path": .string("a.swift")]),
                tool("edit_file", ["path": .string("a.swift")])
            ],
            status: nil
        )
        XCTAssertEqual(summary.changes.count, 1)
        XCTAssertEqual(summary.changes.first?.action, .added)
    }

    // MARK: - Titles
}
