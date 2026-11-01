import XCTest
@testable import HermesMobile

final class ToolCallGroupSummaryTests: XCTestCase {
    func testSuccessfulWritesCountDistinctPathsAcrossCalls() {
        let summary = summary(of: [
            call("patch", args: ["path": .string("Sources/App.swift")]),
            call("patch", args: ["path": .string("Sources/App.swift")]),
            call("write_file", args: ["paths": .array([.string("Sources/App.swift"), .string("README.md")])]),
            // The webui unwraps an MCP filesystem write's success text into plain text.
            call(
                "mcp__filesystem__write_file",
                preview: "Successfully wrote to /tmp/a.txt",
                args: ["path": .string("/tmp/a.txt"), "content": .string("hello")],
                isError: false
            ),
            // A failure keyword inside the path is not an error.
            call(
                "mcp__filesystem__write_file",
                preview: "Successfully wrote to /tmp/ENOENT.md",
                args: ["path": .string("/tmp/ENOENT.md"), "content": .string("# ENOENT\n")],
                isError: false
            )
        ])

        XCTAssertEqual(summary.parts, [.changedFiles(4)])
        XCTAssertEqual(summary.otherActionCount, 0)
    }

    func testUnsuccessfulAndPathlessWritesNeverClaimChangedFiles() {
        let summary = summary(of: [
            call("patch", args: ["path": .string("A.swift")], isError: true),
            call("patch", args: ["path": .string("B.swift")], isCompleted: false),
            call("write_file", args: nil),
            call("patch", preview: #"{"success": true, "no_change": true}"#, args: ["path": .string("C.swift")]),
            // The webui unwraps a failed edit's error into plain text.
            call("patch", preview: "Could not find match for old_string in D.swift", args: ["path": .string("D.swift")]),
            call(
                "patch",
                preview: "Found 2 matches for old_string. Provide more context to make it unique, or use replace_all=True. Matches:\n  L1: foo\n  L2: foo",
                args: ["path": .string("E.swift"), "old_string": .string("foo"), "new_string": .string("bar")],
                isError: false
            ),
            call(
                "write_file",
                preview: "Refusing to overwrite /workspace/a.txt: /workspace/a.txt exists but this task has not seen its full current content (never read, only patched, or only a redacted/partial view). Read the file — every page of it, if it needs offset/limit — or use patch for a targeted edit; a stale conversation copy must not overwrite the current disk content. The file was NOT modified. Reload the current contents with read_file (every page, for a file that needs offset/limit), merge the requested change, then call write_file again. For small edits, prefer patch so existing unrelated changes are preserved.",
                args: ["path": .string("/workspace/a.txt"), "content": .string("replacement\n")],
                isError: false
            )
        ])

        XCTAssertEqual(summary.parts, [])
        XCTAssertEqual(summary.otherActionCount, 7)
        XCTAssertEqual(summary.failedCount, 1)
    }

    func testKeepsTwoLeadingKindsByPriorityAndCountsTheRestAsOther() {
        let summary = summary(of: [
            call("read_file", args: ["path": .string("A.swift")]),
            call("search_files", args: ["pattern": .string("retry")]),
            call("terminal", args: ["command": .string("make")]),
            call("web_search", args: ["query": .string("cron syntax")]),
            call("terminal", args: ["command": .string("make test")]),
            call("skill_view", args: ["name": .string("triage")])
        ])

        XCTAssertEqual(summary.parts, [.commands(2), .searches(2)])
        XCTAssertEqual(summary.otherActionCount, 2)
    }

    func testReadsNameFilesOnlyWhenEveryReadHasAKnownPath() {
        let known = summary(of: [
            call("read_file", args: ["path": .string("A.swift")]),
            call("read_file", args: ["path": .string("A.swift")])
        ])
        XCTAssertEqual(known.parts, [.readFiles(1)])

        let unknown = summary(of: [
            call("read_file", args: ["path": .string("A.swift")]),
            call("read_file", args: nil)
        ])
        XCTAssertEqual(unknown.parts, [.readActions(2)])
    }

    private func summary(of toolCalls: [ToolCall]) -> ToolCallGroupSummary {
        ToolCallGroupSummary(entries: ToolCallSummaryFormatter.entries(for: toolCalls, isLive: false))
    }

    private func call(
        _ name: String,
        preview: String? = nil,
        args: [String: JSONValue]?,
        isError: Bool? = nil,
        isCompleted: Bool = true
    ) -> ToolCall {
        ToolCall(name: name, preview: preview, args: args, isError: isError, isCompleted: isCompleted)
    }
}
