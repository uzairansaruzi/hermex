import XCTest
@testable import HermesMobile

final class MarkdownDiffFormatterTests: XCTestCase {
    private func kinds(_ code: String) -> [MarkdownDiffLineKind] {
        MarkdownDiffFormatter.parse(code).lines.map(\.kind)
    }

    func testSingleFileDiff() {
        let document = MarkdownDiffFormatter.parse("""
        --- a/f.swift
        +++ b/f.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
        """)

        XCTAssertEqual(document.lines.map(\.kind), [.fileHeader, .fileHeader, .hunk, .context, .removed, .added, .context])
        XCTAssertEqual(document.additions, 1)
        XCTAssertEqual(document.deletions, 1)
        XCTAssertEqual(document.lines[4].text, "-let b = 2")
    }

    /// The design mock's two-file patch: a removed `--- TODO` SQL comment inside a counted
    /// hunk is a deletion, and a context line whose leading space was trimmed still counts.
    func testMultiFileGitDiffCountsDashedLinesInsideCountedHunks() {
        let document = MarkdownDiffFormatter.parse("""
        diff --git a/Sources/Store/SessionStore.swift b/Sources/Store/SessionStore.swift
        index 3f2a9c1..8b41d07 100644
        --- a/Sources/Store/SessionStore.swift
        +++ b/Sources/Store/SessionStore.swift
        @@ -41,8 +41,11 @@ final class SessionStore {
             func pinned(for server: ServerID) -> [Session] {
        -        sessions.filter { $0.isPinned }
        +        sessions
        +            .filter { $0.serverID == server && $0.isPinned }
        +            .sorted { $0.updatedAt > $1.updatedAt }
             }

             func archive(_ id: Session.ID) async throws {
        -        try await client.send(.archive(id))
        +        let result = try await client.send(.archive(id))
        +        guard result.ok else { throw StoreError.rejected }
                 cache.remove(id)
             }
        diff --git a/db/migrations/0042_sessions.sql b/db/migrations/0042_sessions.sql
        index 91ce0aa..c07d2f4 100644
        --- a/db/migrations/0042_sessions.sql
        +++ b/db/migrations/0042_sessions.sql
        @@ -3,6 +3,6 @@ CREATE TABLE sessions (
           server_id TEXT NOT NULL,
           pinned INTEGER NOT NULL DEFAULT 0,
           updated_at INTEGER NOT NULL
         );
        --- TODO: drop after 2.4
        -CREATE INDEX sessions_pinned ON sessions (pinned);
        +CREATE INDEX sessions_server_pinned
        +  ON sessions (server_id, pinned, updated_at DESC);
        """)

        XCTAssertEqual(document.additions, 7)
        XCTAssertEqual(document.deletions, 4)
        XCTAssertEqual(document.lines.filter { $0.kind == .fileHeader }.count, 8)
        XCTAssertEqual(document.lines.first { $0.text.hasPrefix("--- TODO") }?.kind, .removed)
        XCTAssertEqual(document.lines[11].kind, .context, "a trimmed blank context line")
    }

    /// Plain `diff -u` output has no `diff --git` line; the first hunk's counts end it,
    /// so the next file's `---`/`+++` lines are headers, not a deletion and an addition.
    func testMultiFilePatchWithoutGitLinesEndsEachHunkByItsCounts() {
        let document = MarkdownDiffFormatter.parse("""
        --- a/one.txt
        +++ b/one.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        --- a/two.txt
        +++ b/two.txt
        @@ -1 +1,2 @@
         keep
        +added
        """)

        XCTAssertEqual(document.lines.map(\.kind), [
            .fileHeader, .fileHeader, .hunk, .context, .removed, .added,
            .fileHeader, .fileHeader, .hunk, .context, .added
        ])
        XCTAssertEqual(document.additions, 2)
        XCTAssertEqual(document.deletions, 1)
    }

    func testCountedChangesThatLookLikeFileHeadersStayChanges() {
        XCTAssertEqual(kinds("""
        @@ -1,2 +1,2 @@
        --- x
         keep
        +++ y
        """), [.hunk, .removed, .context, .added])
    }

    func testOmittedHunkCountMeansOneLine() {
        XCTAssertEqual(kinds("""
        @@ -1 +1 @@
        -a
        +b
        --- a/next
        """), [.hunk, .removed, .added, .fileHeader])
    }

    /// Agent-written counts can be anything; an `Int.max` count must bound the hunk, not trap.
    func testMaximalHunkCountsDoNotOverflow() {
        XCTAssertEqual(kinds("""
        @@ -1,9223372036854775807 +1,9223372036854775807 @@
        -a
        +b
        --- c
        """), [.hunk, .removed, .added, .removed])
    }

    /// LLMs write a bare `@@`: no counts bound the hunk, so prefix rules apply and a
    /// `--- `/`+++ ` pair reads as the next file's headers.
    func testBareHunkHeaderFallsBackToPrefixRules() {
        let document = MarkdownDiffFormatter.parse("""
        --- a/x
        +++ b/x
        @@
         context
        -removed
        +added
        --- a/y
        +++ b/y
        @@
        -- sql comment
        +new
        """)

        XCTAssertEqual(document.lines.map(\.kind), [
            .fileHeader, .fileHeader, .hunk, .context, .removed, .added,
            .fileHeader, .fileHeader, .hunk, .removed, .added
        ])
        XCTAssertEqual(document.additions, 2)
        XCTAssertEqual(document.deletions, 2)
    }

    func testNoNewlineMarkerCountsTowardNeitherSide() {
        let document = MarkdownDiffFormatter.parse("""
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """)

        XCTAssertEqual(document.lines.map(\.kind), [.hunk, .removed, .note, .added, .note])
        XCTAssertEqual(document.additions, 1)
        XCTAssertEqual(document.deletions, 1)
    }

    func testRemovedSQLCommentInsideHunkIsARemoval() {
        XCTAssertEqual(kinds("""
        @@ -1,2 +1,1 @@
        -- drop this comment
         SELECT 1;
        """), [.hunk, .removed, .context])
    }

    func testDiffWithoutHunkHeadersUsesPrefixRules() {
        let document = MarkdownDiffFormatter.parse("""
        --- a/file
        +++ b/file
         keep
        -gone
        +here
        """)

        XCTAssertEqual(document.lines.map(\.kind), [.fileHeader, .fileHeader, .context, .removed, .added])
        XCTAssertEqual(document.additions, 1)
        XCTAssertEqual(document.deletions, 1)
    }

    func testCRLFInputSplitsIntoLinesWithoutCarriageReturns() {
        let document = MarkdownDiffFormatter.parse("@@ -1 +1 @@\r\n-a\r\n+b")

        XCTAssertEqual(document.lines.map(\.kind), [.hunk, .removed, .added])
        XCTAssertEqual(document.lines.map(\.text), ["@@ -1 +1 @@", "-a", "+b"])
    }

    func testEmptyBlockParsesToOneBlankLineAndRendersPlain() {
        let document = MarkdownDiffFormatter.parse("")

        XCTAssertEqual(document.lines.map(\.kind), [.context])
        XCTAssertEqual(document.additions, 0)
        XCTAssertEqual(document.deletions, 0)
        XCTAssertNil(MarkdownDiffFormatter.document(for: "", language: "diff", isStreaming: false))
    }

    /// Only a settled diff or patch fence within the highlighter's size guards is styled;
    /// everything else keeps today's plain code block.
    func testDocumentStylesOnlySettledDiffFencesWithinSizeGuards() {
        let diff = "@@ -1 +1 @@\n-a\n+b"

        XCTAssertNotNil(MarkdownDiffFormatter.document(for: diff, language: "diff", isStreaming: false))
        XCTAssertNotNil(MarkdownDiffFormatter.document(for: diff, language: "Patch", isStreaming: false))
        XCTAssertNil(MarkdownDiffFormatter.document(for: diff, language: "diff", isStreaming: true))
        XCTAssertNil(MarkdownDiffFormatter.document(for: diff, language: "swift", isStreaming: false))
        XCTAssertNil(MarkdownDiffFormatter.document(for: diff, language: nil, isStreaming: false))

        let tooManyLines = Array(repeating: "+x", count: MarkdownHighlightPolicy.maxHighlightedCodeLineCount + 1)
            .joined(separator: "\n")
        XCTAssertNil(MarkdownDiffFormatter.document(for: tooManyLines, language: "diff", isStreaming: false))

        let longLine = "+" + String(repeating: "x", count: MarkdownHighlightPolicy.maxHighlightedCodeLineLength)
        XCTAssertNil(MarkdownDiffFormatter.document(for: longLine, language: "diff", isStreaming: false))
    }

    func testLongDiffCollapsesToTheFirstEightyLinesUntilExpanded() {
        let long = MarkdownDiffFormatter.parse(
            Array(repeating: "+x", count: MarkdownDiffFormatter.collapsedLineLimit + 1).joined(separator: "\n")
        )
        XCTAssertTrue(long.isCollapsible)
        XCTAssertEqual(long.visibleLines(showingAll: false).count, 80)
        XCTAssertEqual(long.visibleLines(showingAll: true).count, 81)
        XCTAssertEqual(long.additions, 81, "counts cover every line, not just the visible ones")

        let short = MarkdownDiffFormatter.parse(
            Array(repeating: "+x", count: MarkdownDiffFormatter.collapsedLineLimit).joined(separator: "\n")
        )
        XCTAssertFalse(short.isCollapsible)
        XCTAssertEqual(short.visibleLines(showingAll: false).count, 80)
    }

    func testAccessibilityLabelsNameTheChangeWithoutThePrefix() {
        let lines = MarkdownDiffFormatter.parse("@@ -1,2 +1,1 @@\n-old\n+new\n-").lines

        XCTAssertEqual(DiffCodeBlockText.accessibilityLabel(for: lines[0]), "@@ -1,2 +1,1 @@")
        XCTAssertEqual(DiffCodeBlockText.accessibilityLabel(for: lines[1]), "removed, old")
        XCTAssertEqual(DiffCodeBlockText.accessibilityLabel(for: lines[2]), "added, new")
        XCTAssertEqual(DiffCodeBlockText.accessibilityLabel(for: lines[3]), "removed, blank")
    }
}
