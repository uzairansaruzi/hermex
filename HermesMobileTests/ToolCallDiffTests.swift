import XCTest
@testable import HermesMobile

final class ToolCallDiffTests: XCTestCase {
    /// hermes-agent `patch` output: `difflib.unified_diff` with `a/`/`b/` headers and a trailing newline.
    private let unifiedDiff = """
    --- a/HermesMobile/App.swift
    +++ b/HermesMobile/App.swift
    @@ -9,4 +9,6 @@
         var body: some Scene {
             WindowGroup {
    -            ContentView()
    +            ContentView(auth: auth)
    +                .modelContainer(container)
    +                .tint(.accentColor)
             }

    """

    private let replacementArgs: [String: JSONValue] = [
        "path": .string("HermesMobile/App.swift"),
        "old_string": .string("let b = 2"),
        "new_string": .string("let b = 3\nlet c = 4"),
        // The webui stringifies every argument value.
        "replace_all": .string("False")
    ]

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private func patchResult(diff: String) throws -> String {
        try json(["success": true, "diff": diff, "files_modified": ["HermesMobile/App.swift"]])
    }

    private func call(_ name: String, preview: String?, args: [String: JSONValue], isCompleted: Bool = true) -> ToolCall {
        ToolCall(name: name, preview: preview, args: args, isCompleted: isCompleted)
    }

    // MARK: - Result sources

    func testPatchResultDiffIsTheSourceAndItsCountsMatch() throws {
        let toolCall = call("patch", preview: try patchResult(diff: unifiedDiff), args: replacementArgs)

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: toolCall))
        XCTAssertEqual(diff.source, .resultDiff)
        XCTAssertEqual(diff.counts, ToolCallDiff.Counts(additions: 3, deletions: 1))
        XCTAssertFalse(diff.isTruncated)
        XCTAssertEqual(
            diff.document.lines.map(\.kind),
            [.fileHeader, .fileHeader, .hunk, .context, .context, .removed, .added, .added, .added, .context],
            "the real diff keeps its headers and context, and the trailing newline adds no blank row"
        )
        XCTAssertTrue(diff.hidesResult)
        XCTAssertEqual(diff.consumedArgumentKeys, ["old_string", "new_string"])
    }

    func testEscapedAndDoubleEncodedResultsResolveTheSameDiff() throws {
        let plain = try patchResult(diff: unifiedDiff)
        let escaped = plain.replacingOccurrences(of: "\"", with: #"\""#)
        let doubleEncoded = try json(plain)
        for preview in [escaped, doubleEncoded] {
            let diff = try XCTUnwrap(ToolCallDiff.resolve(for: call("patch", preview: preview, args: [:])), preview)
            XCTAssertEqual(diff.source, .resultDiff, preview)
            XCTAssertEqual(diff.counts, ToolCallDiff.Counts(additions: 3, deletions: 1), preview)
            XCTAssertEqual(
                diff.document.lines.map(\.kind),
                [.fileHeader, .fileHeader, .hunk, .context, .context, .removed, .added, .added, .added, .context],
                preview
            )
        }
    }

    /// hermes-agent appends AGENTS.md-style subdirectory hints after "\n\n" to the
    /// stored result, so a reloaded row's snippet is no longer valid JSON.
    private func withHints(_ result: String, paddedTo length: Int? = nil) -> String {
        let hinted = result + "\n\n[Subdirectory context discovered: HermesMobile/AGENTS.md]\n# Agent notes\n"
        guard let length else { return hinted }
        let padding = String(repeating: "x", count: length - hinted.unicodeScalars.count)
        return hinted + padding
    }

    func testFailedEnvelopeFollowedByHintsResolvesNothing() throws {
        let failure = try json(["success": false, "error": "Could not find a match for old_string in the file"])
        let preview = withHints(failure, paddedTo: 4_000)
        XCTAssertEqual(preview.unicodeScalars.count, 4_000, "the webui snippet cap, so the result reads as cut off")

        XCTAssertNil(
            ToolCallDiff.resolve(for: call("patch", preview: preview, args: replacementArgs)),
            "a failed edit never shows its requested args as an applied diff"
        )
    }

    func testEnvelopeFollowedByHintsKeepsItsResultDiff() throws {
        let preview = withHints(try patchResult(diff: unifiedDiff))

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: call("patch", preview: preview, args: replacementArgs)))
        XCTAssertEqual(diff.source, .resultDiff)
        XCTAssertEqual(diff.counts, ToolCallDiff.Counts(additions: 3, deletions: 1))
    }

    func testPlainUnifiedDiffResultIsTheSource() throws {
        let toolCall = call("mcp_filesystem_edit_file", preview: unifiedDiff, args: ["path": .string("App.swift")])

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: toolCall))
        XCTAssertEqual(diff.source, .resultText)
        XCTAssertEqual(diff.counts, ToolCallDiff.Counts(additions: 3, deletions: 1))
        XCTAssertTrue(diff.hidesResult)
    }

    // MARK: - Argument sources and truncation

    func testResultCutAtTheSnippetLimitFallsBackToTheArguments() throws {
        let longDiff = unifiedDiff + String(repeating: " context line\n", count: 400)
        let cutPreview = String(String.UnicodeScalarView(try patchResult(diff: longDiff).unicodeScalars.prefix(4_000)))
        let toolCall = call("patch", preview: cutPreview, args: replacementArgs)

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: toolCall))
        XCTAssertEqual(diff.source, .argumentReplacement)
        XCTAssertFalse(diff.isTruncated)
        XCTAssertEqual(diff.counts, ToolCallDiff.Counts(additions: 2, deletions: 1))
        XCTAssertEqual(
            diff.document.lines.map(\.text),
            ["-let b = 2", "+let b = 3", "+let c = 4"],
            "the synthetic @@ header that keeps the parser counting is not drawn"
        )
        XCTAssertTrue(diff.hidesResult, "a cut-off result never shows as raw JSON next to an argument diff")
        XCTAssertEqual(diff.consumedArgumentKeys, ["old_string", "new_string"])
    }

    func testPaginatedNoticeMarksTheResultCutOff() throws {
        let longDiff = unifiedDiff + String(repeating: " context line\n", count: 400)
        let clipped = String(String.UnicodeScalarView(try patchResult(diff: longDiff).unicodeScalars.prefix(4_096)))
            + "\n\n[Tool output truncated in paginated session response; load the full transcript to inspect the complete result.]"

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: call("patch", preview: clipped, args: replacementArgs)))
        XCTAssertEqual(diff.source, .argumentReplacement)
        XCTAssertTrue(diff.hidesResult)
    }

    func testReplaceAllArgumentsDrawOneReplacementWithoutCounts() throws {
        let longDiff = unifiedDiff + String(repeating: " context line\n", count: 400)
        let cutPreview = String(String.UnicodeScalarView(try patchResult(diff: longDiff).unicodeScalars.prefix(4_000)))
        var args = replacementArgs
        args["replace_all"] = .string("True")

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: call("patch", preview: cutPreview, args: args)))
        XCTAssertEqual(diff.source, .argumentReplacement)
        XCTAssertEqual(diff.document.lines.map(\.text), ["-let b = 2", "+let b = 3", "+let c = 4"])
        XCTAssertNil(diff.counts, "one pair's counts would understate an edit that replaced every occurrence")
        XCTAssertFalse(diff.isTruncated, "the pair itself arrived whole, so no Partial diff caption")
    }

    func testCutArgumentMarksTheDiffTruncatedWithoutCounts() throws {
        let cutPreview = String(repeating: "x", count: 4_000)
        let toolCall = call("patch", preview: cutPreview, args: [
            "path": .string("App.swift"),
            // The webui cuts content arguments at 4,000 characters and appends "...".
            "old_string": .string(String(repeating: "line\n", count: 800) + "..."),
            "new_string": .string("b")
        ])

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: toolCall))
        XCTAssertTrue(diff.isTruncated)
        XCTAssertNil(diff.counts, "counts from a cut-off source would undercount")
        XCTAssertEqual(diff.document.lines.count, 801)
        XCTAssertFalse(diff.document.lines.contains { $0.text.contains("...") },
                       "the server's ... marker is not drawn as file content")
    }

    func testRemovedLineThatLooksLikeAFileHeaderCountsAsARemoval() throws {
        let toolCall = call("patch", preview: nil, args: [
            "old_string": .string("-- note\nkeep"),
            "new_string": .string("keep")
        ], isCompleted: false)

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: toolCall))
        XCTAssertEqual(diff.document.lines.map(\.kind), [.removed, .removed, .added])
        XCTAssertEqual(diff.document.lines.first?.text, "--- note")
        XCTAssertEqual(diff.counts, ToolCallDiff.Counts(additions: 1, deletions: 2))
    }

    func testWrittenContentIsAllAdditionsWithUnknownDeletions() throws {
        let toolCall = call(
            "write_file",
            preview: try json(["bytes_written": 17, "dirs_created": false]),
            args: ["path": .string("docs/Notes.md"), "content": .string("# Notes\n\n- one\n")]
        )

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: toolCall))
        XCTAssertEqual(diff.source, .argumentContent)
        XCTAssertEqual(diff.document.lines.map(\.text), ["+# Notes", "+", "+- one"])
        XCTAssertEqual(diff.counts, ToolCallDiff.Counts(additions: 3, deletions: nil))
        XCTAssertFalse(diff.hidesResult)
        XCTAssertEqual(diff.consumedArgumentKeys, ["content"])
    }

    // MARK: - No diff

    func testNonEditRowsResolveNothing() {
        let terminal = call("terminal", preview: unifiedDiff, args: ["command": .string("git diff")])
        XCTAssertNil(ToolCallDiff.resolve(for: terminal))
    }

    func testFailedOrNoOpEditsResolveNothing() throws {
        // The webui unwraps a failed patch's `error` into plain text.
        let webuiFailure = call("patch", preview: "Could not find match for old_string in App.swift", args: replacementArgs)
        let envelopeFailure = call("patch", preview: try json(["success": false, "error": "Could not find match"]), args: replacementArgs)
        let noChange = call("patch", preview: try json(["success": true, "no_change": true, "note": "already applied"]), args: replacementArgs)

        XCTAssertNil(ToolCallDiff.resolve(for: webuiFailure))
        XCTAssertNil(ToolCallDiff.resolve(for: envelopeFailure))
        XCTAssertNil(ToolCallDiff.resolve(for: noChange))
    }

    func testCallTheServerMarkedFailedNeverDrawsItsArguments() {
        let failed = ToolCall(name: "patch", preview: nil, args: replacementArgs, isError: true, isCompleted: true)

        XCTAssertNil(ToolCallDiff.resolve(for: failed), "the requested change never landed")
    }

    // MARK: - Bots and the opened body

    func testBotToolCompleteCarriesTheFullResultDiff() throws {
        let longDiff = unifiedDiff + String(repeating: "+added line\n", count: 400)
        let fullDiff = longDiff.replacingOccurrences(of: "@@ -9,4 +9,6 @@", with: "@@ -9,4 +9,406 @@")
        var activity = BotTurnActivity()
        activity.apply(type: "tool.complete", payload: .object([
            "tool_id": .string("t1"),
            "name": .string("patch"),
            "args": .object(["path": .string("HermesMobile/App.swift"), "old_string": .string("x"), "new_string": .string("y")]),
            "result": .object(["success": .bool(true), "diff": .string(fullDiff)])
        ]))

        let diff = try XCTUnwrap(ToolCallDiff.resolve(for: activity.toolCalls[0]))
        XCTAssertEqual(diff.source, .resultDiff)
        XCTAssertEqual(diff.counts, ToolCallDiff.Counts(additions: 403, deletions: 1))
    }

    func testOpenedContentReplacesTheArgumentsAndResultTheDiffCameFrom() throws {
        let patch = call("patch", preview: try patchResult(diff: unifiedDiff), args: replacementArgs)
        let opened = ToolCallDisplayFormatter.openedContent(for: patch)
        XCTAssertNotNil(opened.diff)
        XCTAssertEqual(opened.argumentRows.map(\.key), ["path", "replace_all"])
        XCTAssertNil(opened.result)

        let write = call(
            "write_file",
            preview: try json(["bytes_written": 5, "dirs_created": false]),
            args: ["path": .string("Notes.md"), "content": .string("hello")]
        )
        let openedWrite = ToolCallDisplayFormatter.openedContent(for: write)
        XCTAssertEqual(openedWrite.argumentRows.map(\.key), ["path"])
        XCTAssertEqual(openedWrite.result?.text, "bytes_written: 5\ndirs_created: false")
    }
}
