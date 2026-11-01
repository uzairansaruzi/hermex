import XCTest
@testable import HermesMobile

final class SlashCommandExecutorTests: XCTestCase {
    func testParseClearWithoutArgs() {
        let parsed = SlashCommandExecutor.parse("/clear")
        XCTAssertEqual(parsed?.command?.name, "clear")
        XCTAssertEqual(parsed?.name, "clear")
        XCTAssertEqual(parsed?.args, "")
    }

    func testParseModelWithArgs() {
        let parsed = SlashCommandExecutor.parse("/model gpt-4")
        XCTAssertEqual(parsed?.command?.name, "model")
        XCTAssertEqual(parsed?.name, "model")
        XCTAssertEqual(parsed?.args, "gpt-4")
    }

    func testParseBranchWithTitle() {
        let parsed = SlashCommandExecutor.parse("/branch Planning Copy")
        XCTAssertEqual(parsed?.command?.name, "branch")
        XCTAssertEqual(parsed?.name, "branch")
        XCTAssertEqual(parsed?.args, "Planning Copy")

        let alias = SlashCommandExecutor.parse("/fork Planning Copy")
        XCTAssertEqual(alias?.command?.name, "fork")
        XCTAssertEqual(alias?.command?.handler, .serverSide(.branch))
        XCTAssertEqual(alias?.name, "fork")
        XCTAssertEqual(alias?.args, "Planning Copy")
    }

    func testParseUnknownCommand() {
        let parsed = SlashCommandExecutor.parse("/unknown")
        XCTAssertNil(parsed?.command)
        XCTAssertEqual(parsed?.name, "unknown")
        XCTAssertEqual(parsed?.args, "")
    }

    func testParseBusyInputCommands() {
        for name in ["queue", "steer", "interrupt", "status", "btw", "background", "bg", "goal"] {
            let parsed = SlashCommandExecutor.parse("/\(name)")
            XCTAssertEqual(parsed?.command?.name, name)
            XCTAssertEqual(parsed?.name, name)
            XCTAssertEqual(parsed?.args, "")
        }

        XCTAssertEqual(SlashCommandExecutor.parse("/queue follow up")?.command?.handler, .serverSide(.queue))
        XCTAssertEqual(SlashCommandExecutor.parse("/steer prefer tests")?.command?.handler, .serverSide(.steer))
        XCTAssertEqual(SlashCommandExecutor.parse("/interrupt start over")?.command?.handler, .serverSide(.interrupt))
        XCTAssertEqual(SlashCommandExecutor.parse("/status")?.command?.handler, .serverSide(.status))
        XCTAssertEqual(SlashCommandExecutor.parse("/btw explain this")?.command?.handler, .serverSide(.btw))
        XCTAssertEqual(SlashCommandExecutor.parse("/background audit this")?.command?.handler, .serverSide(.background))
        XCTAssertEqual(SlashCommandExecutor.parse("/bg audit this")?.command?.handler, .serverSide(.background))
    }

    func testEmptyArgsHandlingTrimsWhitespace() {
        let parsed = SlashCommandExecutor.parse("  /model   ")
        XCTAssertEqual(parsed?.command?.name, "model")
        XCTAssertEqual(parsed?.args, "")
    }

    func testNonSlashTextReturnsNil() {
        XCTAssertNil(SlashCommandExecutor.parse("hello"))
    }
}
