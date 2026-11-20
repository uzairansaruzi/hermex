import XCTest
@testable import HermesMobile

@MainActor final class BotSlashCommandTests: XCTestCase {
    private func catalogReply(
        skills: [String: BotJSON] = ["/work": .object(["origin": .string("user"), "usage": .number(3)]),
                                     "/write-tests": .object(["origin": .string("bundled")])],
        pairs: [BotJSON] = [.array([.string("/model"), .string("Switch model")]),
                            .array([.string("/work"), .string("Do focused work")]),
                            .array([.string("/write-tests"), .string("Add tests")])],
        canon: [String: BotJSON] = ["/model": .string("/model"), "/m": .string("/model")],
        commands: [String: BotJSON] = ["/model": .object(["argument_mode": .string("options")])]
    ) -> BotJSON {
        .object([
            "skills": .object(skills), "pairs": .array(pairs), "canon": .object(canon),
            "commands": .object(commands), "categories": .array([]),
            "skill_count": .number(Double(skills.count)), "warning": .string(""),
            "future_field": .object(["nested": .bool(true)])
        ])
    }

    func testCatalogReadsSkillsWithTheirDescriptions() {
        let skills = BotSlashCatalog.skills(from: catalogReply())
        XCTAssertEqual(skills.map(\.name), ["work", "write-tests"])
        XCTAssertEqual(skills.first?.description, "Do focused work")
        XCTAssertEqual(skills.first?.category, "user")
        XCTAssertEqual(skills.last?.category, "bundled")
        XCTAssertEqual(skills.last?.description, "Add tests")
    }

    func testCatalogDropsSkillsShadowedByACommand() {
        let reply = catalogReply(
            skills: ["/work": .object([:]), "/deploy": .object([:]), "/m": .object([:])],
            pairs: [.array([.string("/deploy"), .string("exec: ./deploy.sh")])],
            canon: ["/deploy": .string("/deploy"), "/m": .string("/model")],
            commands: [:])
        XCTAssertEqual(BotSlashCatalog.skills(from: reply).map(\.name), ["work"])
    }

    func testCatalogToleratesAMissingOrMalformedReply() {
        XCTAssertTrue(BotSlashCatalog.skills(from: .object([:])).isEmpty)
        XCTAssertTrue(BotSlashCatalog.skills(from: .object(["skills": .string("nope")])).isEmpty)
        let ragged = BotJSON.object([
            "skills": .object(["/work": .null, "no-slash": .object([:]), "/two words": .object([:]), "/": .object([:])]),
            "pairs": .array([.string("not a row"), .array([.string("/work")])])
        ])
        XCTAssertEqual(BotSlashCatalog.skills(from: ragged).map(\.name), ["work"])
        XCTAssertNil(BotSlashCatalog.skills(from: ragged).first?.description)
    }

    func testRankingMatchesTheSessionsPanel() {
        let skills = [
            SkillSlashSuggestion(name: "review-notes", category: nil, description: "Tidy meeting notes"),
            SkillSlashSuggestion(name: "code-review", category: nil, description: "Read a diff"),
            SkillSlashSuggestion(name: "triage", category: nil, description: "Review the inbox")
        ]
        XCTAssertEqual(SlashSkillFormatter.matching("review", in: skills).map(\.name),
                       ["review-notes", "code-review", "triage"])
        XCTAssertEqual(SlashSkillFormatter.matching("nothing-here", in: skills).map(\.name), [])
    }

    func testInvocationReadsTheOpeningNameAndArgument() {
        XCTAssertEqual(BotSlashCatalog.invocation(in: "  /work fix the leak "),
                       BotSlashInvocation(name: "work", argument: "fix the leak"))
        XCTAssertEqual(BotSlashCatalog.invocation(in: "/work"), BotSlashInvocation(name: "work", argument: ""))
        XCTAssertEqual(BotSlashCatalog.invocation(in: "/work\nfix it"),
                       BotSlashInvocation(name: "work", argument: "fix it"))
        XCTAssertNil(BotSlashCatalog.invocation(in: "/"))
        XCTAssertNil(BotSlashCatalog.invocation(in: "hello /work"))
    }
}
