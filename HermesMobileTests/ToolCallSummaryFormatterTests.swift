import XCTest
@testable import HermesMobile

final class ToolCallSummaryFormatterTests: XCTestCase {
    // MARK: - Shell wrapper unwrap

    func testUnwrapsKnownShellWrappers() {
        XCTAssertEqual(ToolCallSummaryFormatter.unwrappingShellWrapper(#"bash -lc "git status""#), "git status")
        XCTAssertEqual(ToolCallSummaryFormatter.unwrappingShellWrapper("/bin/zsh -c 'ls -la'"), "ls -la")
        XCTAssertEqual(ToolCallSummaryFormatter.unwrappingShellWrapper("sh -c make test"), "make test")
        XCTAssertEqual(ToolCallSummaryFormatter.unwrappingShellWrapper("pwsh -Command 'Get-ChildItem'"), "Get-ChildItem")
        XCTAssertEqual(ToolCallSummaryFormatter.unwrappingShellWrapper("cmd.exe /c dir"), "dir")
    }

    func testLeavesPlainCommandsAlone() {
        XCTAssertEqual(ToolCallSummaryFormatter.unwrappingShellWrapper("git status"), "git status")
        XCTAssertEqual(ToolCallSummaryFormatter.unwrappingShellWrapper("bash -lc"), "bash -lc")
        XCTAssertEqual(ToolCallSummaryFormatter.unwrappingShellWrapper("bash script.sh"), "bash script.sh")
    }

    // MARK: - Exit code

    func testStripsTrailingExitCodeMarker() {
        let stripped = ToolCallSummaryFormatter.strippingTrailingExitCode("hello\n<exited with exit code 2>")
        XCTAssertEqual(stripped.output, "hello")
        XCTAssertEqual(stripped.exitCode, 2)

        let markerOnly = ToolCallSummaryFormatter.strippingTrailingExitCode("<exited with exit code 0>")
        XCTAssertNil(markerOnly.output)
        XCTAssertEqual(markerOnly.exitCode, 0)

        let plain = ToolCallSummaryFormatter.strippingTrailingExitCode("  done  ")
        XCTAssertEqual(plain.output, "done")
        XCTAssertNil(plain.exitCode)
    }

    func testShellRowUsesUnwrappedCommandAndNonZeroExitCodeFails() throws {
        let toolCall = ToolCall(
            name: "terminal",
            preview: "make: *** No rule\n<exited with exit code 2>",
            args: ["command": .string("bash -lc 'make test'"), "workdir": .string("/tmp")],
            isCompleted: true
        )

        let row = try XCTUnwrap(ToolCallSummaryFormatter.row(for: toolCall))
        XCTAssertEqual(row.icon, "terminal")
        XCTAssertEqual(row.summary, "Ran")
        XCTAssertEqual(row.detail, "make test")
        XCTAssertEqual(row.status, .failure)
    }

    // MARK: - Changed files and read ranges

    func testChangedFilePreviewShowsFirstFileAndRemainder() throws {
        let patch = ToolCall(
            name: "patch",
            preview: nil,
            args: [
                "edits": .array([
                    .object(["path": .string("Sources/App/One.swift")]),
                    .object(["path": .string("Sources/App/Two.swift")]),
                    .object(["path": .string("Sources/App/Three.swift")])
                ])
            ],
            isCompleted: true
        )
        let patchRow = try XCTUnwrap(ToolCallSummaryFormatter.row(for: patch))
        XCTAssertEqual(patchRow.summary, "Updated")
        XCTAssertEqual(patchRow.detail, "One.swift +2 more")

        let write = ToolCall(
            name: "write_file",
            preview: nil,
            args: ["path": .string("~/project/Notes.md"), "content": .string("secret body")],
            isCompleted: true
        )
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: write)?.detail, "Notes.md")
    }

    func testReadRowShowsLineRangeAndBasename() throws {
        let toolCall = ToolCall(
            name: "read_file",
            preview: "line 12",
            args: ["path": .string("/repo/Sources/File.swift"), "offset": .number(12), "limit": .number(20)],
            isCompleted: true
        )

        let row = try XCTUnwrap(ToolCallSummaryFormatter.row(for: toolCall))
        XCTAssertEqual(row.icon, "doc.text")
        XCTAssertEqual(row.summary, "Read")
        XCTAssertEqual(row.detail, "L12-31 · File.swift")
        XCTAssertEqual(row.status, .success)
    }

    // MARK: - Failure heuristics

    func testFailureTextHeuristics() {
        XCTAssertTrue(ToolCallSummaryFormatter.looksLikeFailure("zsh: command not found: foo"))
        XCTAssertTrue(ToolCallSummaryFormatter.looksLikeFailure("Error: ENOENT: no such file"))
        XCTAssertTrue(ToolCallSummaryFormatter.looksLikeFailure("Exit code: 3"))
        XCTAssertTrue(ToolCallSummaryFormatter.looksLikeFailure("Exit code: -1"))
        XCTAssertTrue(ToolCallSummaryFormatter.looksLikeFailure("Error: BLOCKED: Command denied by user."))
        XCTAssertFalse(ToolCallSummaryFormatter.looksLikeFailure("Exit code: 0"))
        XCTAssertFalse(ToolCallSummaryFormatter.looksLikeFailure("Successfully wrote 3 files"))
    }

    func testDeniedCommandEnvelopeFailsTheRow() {
        let toolCall = ToolCall(
            name: "terminal",
            preview: #"{"error":"BLOCKED: Command denied by user.","exit_code":-1}"#,
            args: ["command": .string("rm -rf /tmp/x")],
            isCompleted: true
        )
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: toolCall)?.status, .failure)
    }

    func testResultTextCanFailACompletedCall() {
        let toolCall = ToolCall(
            name: "read_file",
            preview: "No such file or directory: missing.txt",
            args: ["path": .string("missing.txt")],
            isCompleted: true
        )
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: toolCall)?.status, .failure)
    }

    func testNeverCompletedCallIsInterrupted() {
        let toolCall = ToolCall(name: "terminal", preview: nil, args: ["command": .string("sleep 60")])
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: toolCall)?.status, .interrupted)
    }

    // MARK: - Drop rule and fallbacks

    func testDropsRowsWithoutSignalButKeepsFailures() {
        let empty = ToolCall(name: nil, preview: nil, args: nil, isCompleted: true)
        let failed = ToolCall(name: nil, preview: nil, args: nil, isError: true, isCompleted: true)
        let named = ToolCall(name: "terminal", preview: nil, args: nil, isCompleted: true)

        let entries = ToolCallSummaryFormatter.entries(for: [empty, failed, named])
        XCTAssertEqual(entries.map(\.toolCall.id), [failed.id, named.id])
        XCTAssertEqual(entries.first?.row.status, .failure)
    }

    func testDetailFallsBackToFirstResultLineWhenThereIsNoTarget() throws {
        let toolCall = ToolCall(
            name: "terminal",
            preview: "  12 files   changed\nmore output\n<exited with exit code 0>",
            args: ["workdir": .string("/tmp")],
            isCompleted: true
        )

        let row = try XCTUnwrap(ToolCallSummaryFormatter.row(for: toolCall))
        XCTAssertEqual(row.detail, "12 files changed")
        XCTAssertEqual(row.status, .success)
    }

    func testUnknownToolsUseTheirShortName() throws {
        let mcp = ToolCall(name: "mcp__slack__post", preview: nil, args: ["channel": .string("#ops")], isCompleted: true)
        let mcpRow = try XCTUnwrap(ToolCallSummaryFormatter.row(for: mcp))
        XCTAssertEqual(mcpRow.summary, "slack/post")
        XCTAssertEqual(mcpRow.icon, "powerplug")
        XCTAssertNil(mcpRow.detail)

        let clarify = ToolCall(name: "clarify", preview: nil, args: ["question": .string("Which?")], isCompleted: true)
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: clarify)?.summary, "clarify")
    }

    func testSearchAndWebRowsShowTheQuery() {
        let search = ToolCall(name: "search_files", preview: nil, args: ["pattern": .string("TODO")], isCompleted: true)
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: search)?.summary, "Searched")
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: search)?.detail, "TODO")

        let web = ToolCall(name: "web_search", preview: nil, args: ["query": .string("swift  regex")], isCompleted: true)
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: web)?.summary, "Checked")
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: web)?.detail, "swift regex")
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: web)?.icon, "globe")
    }

    func testCopyTextIncludesRowArgumentsAndResult() {
        let toolCall = ToolCall(
            name: "terminal",
            preview: "ok",
            args: ["command": .string("ls")],
            isCompleted: true
        )

        XCTAssertEqual(ToolCallSummaryFormatter.copyText(for: toolCall), "Ran ls\ncommand: ls\nok")
    }
}
