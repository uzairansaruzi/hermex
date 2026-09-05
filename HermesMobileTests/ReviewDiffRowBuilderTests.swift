import XCTest
@testable import HermesMobile

final class ReviewDiffRowBuilderTests: XCTestCase {
    private func file(_ path: String, oldPath: String? = nil, status: String = "M", additions: Int? = nil) throws -> GitFile {
        var json: [String: Any] = ["path": path, "status": status, "unstaged": true]
        if let oldPath { json["old_path"] = oldPath }
        if let additions { json["additions"] = additions }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitFile.self, from: data)
    }

    private func diff(_ text: String, binary: Bool? = nil, tooLarge: Bool? = nil) throws -> GitDiff {
        var json: [String: Any] = ["diff": text]
        if let binary { json["binary"] = binary }
        if let tooLarge { json["too_large"] = tooLarge }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitDiff.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testLoadedDiffBuildsHeaderHunkAndLineRowsWithStableIDs() throws {
        let raw = "@@ -1,3 +1,3 @@\n context\n-old value\n+new value\n\\ No newline at end of file"
        let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: try file("a/b.swift"), state: .loaded(try diff(raw))))

        XCTAssertEqual(rows.map(\.id), ["a/b.swift:header", "a/b.swift:hunk:0", "a/b.swift:line:0:0", "a/b.swift:line:0:1", "a/b.swift:line:0:2", "a/b.swift:line:0:3"])
        XCTAssertEqual(rows.map(\.fileID), Array(repeating: "a/b.swift", count: 6))

        let header = try XCTUnwrap(rows[0].fileHeader)
        XCTAssertEqual(header.path, "a/b.swift")
        XCTAssertNil(header.previousPath)
        XCTAssertEqual(header.additions, 1, "Counts fall back to the hunk when the file has none.")
        XCTAssertEqual(header.deletions, 1)

        XCTAssertEqual(rows[1].kind, .hunk("Lines 1-3"))
        let context = try XCTUnwrap(rows[2].line)
        XCTAssertEqual(context.change, .context)
        XCTAssertEqual(context.content, "context", "The diff prefix character is dropped.")
        XCTAssertEqual(context.oldLineNumber, 1)
        XCTAssertEqual(context.newLineNumber, 1)
        XCTAssertEqual(rows[3].line?.change, .deletion)
        XCTAssertEqual(rows[4].line?.change, .addition)
        XCTAssertEqual(rows[5].line?.content, "\\ No newline at end of file", "Markers keep their text.")
    }

    func testPairedLinesCarryWordDiffRanges() throws {
        let raw = "@@ -1,1 +1,1 @@\n-let value = compute(alpha)\n+let value = compute(beta)"
        let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: try file("x.swift"), state: .loaded(try diff(raw))))

        XCTAssertEqual(rows[2].line?.wordDiffRanges, [20..<25])
        XCTAssertEqual(rows[3].line?.wordDiffRanges, [20..<24])
    }

    func testTabsExpandToSpacesForTheCharacterGrid() throws {
        let raw = "@@ -1,1 +1,1 @@\n+\tindented"
        let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: try file("x.swift"), state: .loaded(try diff(raw))))
        XCTAssertEqual(rows[2].line?.content, "    indented")
    }

    func testRenameShowsPreviousPathAndFileCountsWin() throws {
        let renamed = try file("new.swift", oldPath: "old.swift", status: "R", additions: 7)
        let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: renamed, state: .loaded(try diff("@@ -1 +1 @@\n-a\n+b"))))
        let header = try XCTUnwrap(rows[0].fileHeader)
        XCTAssertEqual(header.previousPath, "old.swift")
        XCTAssertEqual(header.displayPath, "old.swift → new.swift")
        XCTAssertEqual(header.changeKind, .renamed)
        XCTAssertEqual(header.additions, 7, "Server counts win over the parsed hunk.")
    }

    func testNonRenderableStatesBecomeOneNoticeRow() throws {
        let plain = try file("x.swift")
        let cases: [(ReviewDiffFileState, String)] = [
            (.loading, "Loading…"),
            (.failed("Boom"), "Boom"),
            (.loaded(try diff("", binary: true)), "Binary file changed"),
            (.loaded(try diff("", tooLarge: true)), "Diff too large to show."),
            (.loaded(try diff("")), "No Changes")
        ]
        for (state, notice) in cases {
            let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: plain, state: state))
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[1].id, "x.swift:notice")
            XCTAssertEqual(rows[1].kind, .notice(notice))
        }
    }

    func testMultipleFilesConcatenateInOrder() throws {
        let rows = ReviewDiffRowBuilder.rows(for: [
            ReviewDiffFileInput(file: try file("one.swift"), state: .loading),
            ReviewDiffFileInput(file: try file("two.swift"), state: .loaded(try diff("@@ -1 +1 @@\n-a\n+b")))
        ])
        XCTAssertEqual(rows.filter(\.isFileHeader).map(\.fileID), ["one.swift", "two.swift"])
        XCTAssertEqual(rows.count, 2 + 4)
    }
}
