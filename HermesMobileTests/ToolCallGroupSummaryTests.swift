import XCTest
@testable import HermesMobile

final class ToolCallGroupSummaryTests: XCTestCase {
    func testSuccessfulWritesCountDistinctPathsAcrossCalls() {
        let summary = summary(of: [
            call("patch", args: ["path": .string("Sources/App.swift")]),
            call("patch", args: ["path": .string("Sources/App.swift")]),
            call("write_file", args: ["paths": .array([.string("Sources/App.swift"), .string("README.md")])])
        ])

        XCTAssertEqual(summary.parts, [.changedFiles(2)])
        XCTAssertEqual(summary.otherActionCount, 0)
    }

    func testUnsuccessfulAndPathlessWritesNeverClaimChangedFiles() {
        let summary = summary(of: [
            call("patch", args: ["path": .string("A.swift")], isError: true),
            call("patch", args: ["path": .string("B.swift")], isCompleted: false),
            call("write_file", args: nil)
        ])

        XCTAssertEqual(summary.parts, [])
        XCTAssertEqual(summary.otherActionCount, 3)
        XCTAssertEqual(summary.failedCount, 1)
    }

    func testKeepsTwoLeadingKindsByPriorityAndCountsTheRestAsOther() {
        let summary = summary(of: [
            call("read_file", args: ["path": .string("A.swift")]),
            call("search_files", args: ["pattern": .string("retry")]),
            call("terminal", args: ["command": .string("make")]),
            call("search_files", args: ["pattern": .string("cron")]),
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
        args: [String: JSONValue]?,
        isError: Bool? = nil,
        isCompleted: Bool = true
    ) -> ToolCall {
        ToolCall(name: name, preview: nil, args: args, isError: isError, isCompleted: isCompleted)
    }
}
