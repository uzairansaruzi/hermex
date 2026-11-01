import XCTest
@testable import HermesMobile

/// What a Bot connection's `commands.catalog` is read as, and how a draft's opening
/// `/name` is read back out. A Hermes chat's panel and sends are `HermesSlashCommandTests`.
@MainActor final class BotSlashCommandTests: XCTestCase {
    /// `commands.catalog` as 0.21.2 answers it: skill keys in `skills`, every
    /// entry's description in `pairs`, commands in `canon` and `commands`.
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
            // A field this app has never heard of must not cost it the catalog.
            "future_field": .object(["nested": .bool(true)])
        ])
    }

    // MARK: - Catalog decode

    func testCatalogReadsSkillsWithTheirDescriptions() {
        let skills = BotSlashCatalog.skills(from: catalogReply())
        XCTAssertEqual(skills.map(\.name), ["work", "write-tests"])
        XCTAssertEqual(skills.first?.description, "Do focused work")
        XCTAssertEqual(skills.first?.category, "user")
        XCTAssertEqual(skills.last?.category, "bundled")
        XCTAssertEqual(skills.last?.description, "Add tests")
    }

    /// `command.dispatch` resolves quick, plugin and registry commands ahead of
    /// skills, and a quick command can run a shell command on the host. A skill
    /// key that collides with one is never offered.
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

    // MARK: - Ranking

    /// The panel ranks through the same `SlashCommandRanker` the Sessions panel
    /// uses, so a name prefix still beats a word boundary, which beats a
    /// description hit.
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

    // MARK: - Draft parsing

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
