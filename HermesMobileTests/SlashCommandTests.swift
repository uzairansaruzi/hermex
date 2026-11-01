import XCTest
@testable import HermesMobile

final class SlashCommandTests: XCTestCase {

    // MARK: - Catalog matching

    func testMatchingEmptyQueryReturnsAllCommands() {
        let results = SlashCommandCatalog.matching("")
        XCTAssertEqual(results.count, SlashCommandCatalog.allCommands.count)
    }

    func testMatchingIsCaseInsensitive() {
        let lower = SlashCommandCatalog.matching("model")
        let upper = SlashCommandCatalog.matching("MODEL")
        XCTAssertEqual(lower.count, upper.count)
        XCTAssertEqual(lower.first?.name, upper.first?.name)
    }

    func testCommandNamedIsCaseInsensitive() {
        let lower = SlashCommandCatalog.command(named: "model")
        let upper = SlashCommandCatalog.command(named: "MODEL")
        XCTAssertEqual(lower?.name, upper?.name)
    }

    // MARK: - Reasoning levels

    // MARK: - ParsedSlashQuery

    func testParsedQueryMultipleSpaces() {
        let parsed = ParsedSlashQuery(query: "/model   gpt-4")
        XCTAssertEqual(parsed.commandName, "model")
        XCTAssertEqual(parsed.argQuery, "gpt-4")
    }

    func testParsedQueryIsNotSubArgModeForHelp() {
        let parsed = ParsedSlashQuery(query: "/help")
        XCTAssertFalse(parsed.isSubArgMode)
    }

    func testParsedQueryIsNotSubArgModeWithoutSpace() {
        let parsed = ParsedSlashQuery(query: "/model")
        XCTAssertFalse(parsed.isSubArgMode)
    }

    func testParsedQueryIsSubArgModeWithTrailingSpace() {
        let parsed = ParsedSlashQuery(query: "/model ")
        XCTAssertTrue(parsed.isSubArgMode)
    }

    func testParsedQueryTreatsGoalActionsAsSubArgs() {
        let parsed = ParsedSlashQuery(query: "/goal sta")
        XCTAssertEqual(parsed.command?.name, "goal")
        XCTAssertEqual(parsed.command?.subArgs, .goalActions)
        XCTAssertEqual(parsed.argQuery, "sta")
        XCTAssertTrue(parsed.isSubArgMode)
    }

    // MARK: - Skill slash suggestions

    func testSkillSuggestionsTrimAndSortNames() {
        let suggestions = SlashSkillFormatter.suggestions(from: [
            SkillSummary(name: " zed ", category: " coding ", description: " Last ", path: nil),
            SkillSummary(name: nil, category: "coding", description: "Missing name", path: nil),
            SkillSummary(name: "alpha", category: "", description: "", path: nil)
        ])

        XCTAssertEqual(suggestions.map(\.name), ["alpha", "zed"])
        XCTAssertNil(suggestions[0].category)
        XCTAssertEqual(suggestions[1].category, "coding")
        XCTAssertEqual(suggestions[1].description, "Last")
    }

    func testSkillSuggestionsBuildWebUIStyleSlugs() {
        XCTAssertEqual(SlashSkillFormatter.slug(for: "Claude Code"), "claude-code")
        XCTAssertEqual(SlashSkillFormatter.slug(for: "docs_search!!"), "docs-search")
        XCTAssertEqual(SlashSkillFormatter.slug(for: "--Swift---Refactor--"), "swift-refactor")
    }

    func testSkillInvocationSplitsRecognizedSkillAndMessage() throws {
        let suggestions = SlashSkillFormatter.suggestions(from: [
            SkillSummary(name: "Claude Code", category: "coding", description: "Use Claude Code", path: nil)
        ])

        let invocation = SlashSkillFormatter.invocation(
            from: "claude-code open claude code and check for updates",
            suggestions: suggestions
        )

        XCTAssertEqual(invocation?.skill.name, "Claude Code")
        XCTAssertEqual(invocation?.skill.slashName, "claude-code")
        XCTAssertEqual(invocation?.message, "open claude code and check for updates")
        XCTAssertEqual(SlashSkillFormatter.messageText(for: try XCTUnwrap(invocation)), "/claude-code open claude code and check for updates")
    }

    func testSkillInvocationDoesNotTreatSkillOnlyAsMessage() {
        let suggestions = SlashSkillFormatter.suggestions(from: [
            SkillSummary(name: "Claude Code", category: "coding", description: "Use Claude Code", path: nil)
        ])

        XCTAssertNil(SlashSkillFormatter.invocation(from: "claude-code", suggestions: suggestions))
        XCTAssertNil(SlashSkillFormatter.invocation(from: "claude-code ", suggestions: suggestions))
        XCTAssertEqual(SlashSkillFormatter.skillQuery(from: "claude-code "), "claude-code")
    }

    func testSkillInvocationRequiresRecognizedSkillBeforeMessage() {
        let suggestions = SlashSkillFormatter.suggestions(from: [
            SkillSummary(name: "claude-code", category: "coding", description: nil, path: nil)
        ])

        XCTAssertNil(SlashSkillFormatter.invocation(from: "claude maybe a search", suggestions: suggestions))
    }

    // MARK: - Agent slash suggestions

    func testAgentCommandSuggestionsHideCLIOnlyGatewayOnlyAndDuplicateCommands() {
        let suggestions = AgentSlashCommandSuggestion.matching("s", in: [
            AgentCommand(name: "status", description: "Agent status"),
            AgentCommand(name: "shell", description: "CLI only", cliOnly: true),
            AgentCommand(name: "sethome", description: "Gateway only", gatewayOnly: true),
            AgentCommand(name: "session", description: nil)
        ], excluding: ["status"])

        XCTAssertEqual(suggestions.map(\.name), ["session"])
        XCTAssertEqual(suggestions.first?.description, "Agent command")
    }

    // MARK: - Ranking

    private func fields(
        name: String,
        label: String? = nil,
        shortDescription: String? = nil,
        description: String? = nil
    ) -> SlashRankableFields {
        SlashRankableFields(
            name: name,
            label: label,
            shortDescription: shortDescription,
            description: description
        )
    }

    func testScoreRanksNameMatchTiers() {
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "claude-code"), matching: "claude-code"), 0)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "claude-code"), matching: "clau"), 2)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "claude-code"), matching: "code"), 4)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "claude-code"), matching: "ode"), 6)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "claude-code"), matching: "cdc"), 100)
        XCTAssertNil(SlashCommandRanker.score(fields(name: "claude-code"), matching: "zzz"))
    }

    func testScoreDoesNotFuzzyMatchDescriptions() {
        XCTAssertNil(SlashCommandRanker.score(fields(name: "n", shortDescription: "coding"), matching: "cdg"))
        XCTAssertNil(SlashCommandRanker.score(fields(name: "n", description: "refactor swift"), matching: "rfs"))
    }

    func testScoreKeepsTheBestFieldMatch() {
        // A weak name hit still beats a perfect description hit.
        let value = fields(name: "swift-refactor", description: "refactor")
        XCTAssertEqual(SlashCommandRanker.score(value, matching: "refactor"), 4)
    }

    func testRankOrdersByScoreThenLabelThenName() {
        let items = [
            fields(name: "zeta", label: "review notes"),
            fields(name: "review", label: "Review"),
            fields(name: "alpha", label: "review notes"),
            fields(name: "beta", label: "Review board"),
            fields(name: "code-review", label: "Code Review")
        ]

        let ranked = SlashCommandRanker.rank(items, matching: "review") { $0 }

        // Exact name (0) beats label prefix (3), which beats a name boundary
        // hit (4). The three label-prefix ties break by label, then by name.
        XCTAssertEqual(ranked.map(\.name), ["review", "beta", "alpha", "zeta", "code-review"])
    }

    func testRankKeepsCallerOrderForAnEmptyQuery() {
        let items = [fields(name: "zeta"), fields(name: "alpha")]
        XCTAssertEqual(SlashCommandRanker.rank(items, matching: "  ") { $0 }.map(\.name), ["zeta", "alpha"])
    }

    func testRankBoundsResultsToTheBestCandidates() {
        let items = (0..<50).map { fields(name: "skill-\(String(format: "%02d", $0))") }

        let ranked = SlashCommandRanker.rank(items, matching: "skill") { $0 }

        XCTAssertEqual(ranked.count, SlashCommandRanker.resultLimit)
        XCTAssertEqual(ranked.first?.name, "skill-00")
        XCTAssertEqual(ranked.last?.name, "skill-19")
    }

    func testCatalogMatchingPutsTheExactCommandFirst() {
        let results = SlashCommandCatalog.matching("compact")
        XCTAssertEqual(results.first?.name, "compact")
    }

    func testSkillMatchingRanksSlugHitsAboveDescriptionHits() {
        let suggestions = SlashSkillFormatter.suggestions(from: [
            SkillSummary(name: "Deploy Notes", category: "ops", description: "Write the release notes", path: nil),
            SkillSummary(name: "Release", category: "ops", description: "Ship a build", path: nil)
        ])

        XCTAssertEqual(
            SlashSkillFormatter.matching("release", in: suggestions).map(\.name),
            ["Release", "Deploy Notes"]
        )
    }

    func testSkillMatchingIsBoundedButTheWrittenListIsNot() {
        let suggestions = SlashSkillFormatter.suggestions(from: (0..<40).map {
            SkillSummary(name: "skill-\(String(format: "%02d", $0))", category: nil, description: nil, path: nil)
        })

        XCTAssertEqual(SlashSkillFormatter.matching("skill", in: suggestions).count, SlashCommandRanker.resultLimit)
        XCTAssertEqual(SlashSkillFormatter.matching("skill", in: suggestions, limit: .max).count, 40)
    }

    func testAgentCommandRankingIgnoresTheDescriptionPlaceholder() {
        let suggestions = AgentSlashCommandSuggestion.matching("agent", in: [
            AgentCommand(name: "resume", description: nil),
            AgentCommand(name: "agents", description: "List sub-agents")
        ])

        XCTAssertEqual(suggestions.map(\.name), ["agents"])
    }

    // MARK: - Autocomplete ranking passes

    private func skills(_ count: Int) -> [SkillSlashSuggestion] {
        SlashSkillFormatter.suggestions(from: (0..<count).map {
            SkillSummary(name: "skill-\(String(format: "%03d", $0))", category: nil, description: nil, path: nil)
        })
    }

    func testRankingResultsCarryThePassThatProducedThem() {
        let input = SlashAutocompleteRanking(
            mode: .commands,
            query: "mod",
            skills: skills(2),
            agentCommands: []
        )

        let results = input.results()

        XCTAssertEqual(results.input, input)
        XCTAssertEqual(results.commands.first?.name, "model")
    }

    func testSmallCatalogsRankInlineAndLargeOnesDoNot() {
        XCTAssertTrue(
            SlashAutocompleteRanking(mode: .commands, query: "s", skills: skills(10), agentCommands: []).ranksInline
        )
        XCTAssertFalse(
            SlashAutocompleteRanking(mode: .commands, query: "s", skills: skills(200), agentCommands: []).ranksInline
        )
    }

    func testSkillSubArgPassOnlyRanksSkills() {
        let input = SlashAutocompleteRanking(
            mode: .skillSubArgs,
            query: "skill-001",
            skills: skills(5),
            agentCommands: []
        )

        let results = input.results()

        XCTAssertEqual(results.skillSubArgs.map(\.name), ["skill-001"])
        XCTAssertTrue(results.hasNoCommandRows)
    }

    func testSkillsOnlyPassOffersSkillsAndNoCommands() {
        let input = SlashAutocompleteRanking(
            mode: .skillsOnly,
            query: "skill-002",
            skills: skills(5),
            agentCommands: [AgentCommand(name: "resume", description: "Resume a session")]
        )

        let results = input.results()

        XCTAssertEqual(results.skills.map(\.name), ["skill-002"])
        XCTAssertTrue(results.commands.isEmpty)
        XCTAssertTrue(results.agentCommands.isEmpty)
        XCTAssertTrue(results.skillSubArgs.isEmpty)
    }

    func testAgentCommandLookupRecognizesVisibleMetadataCommand() {
        let commands = [
            AgentCommand(name: "resume", description: "Resume a previously-named session"),
            AgentCommand(name: "model", description: "Built-in model command"),
            AgentCommand(name: "browser", description: "CLI only", cliOnly: true)
        ]

        XCTAssertEqual(AgentSlashCommandSuggestion.command(named: "RESUME", in: commands)?.name, "resume")
        XCTAssertNil(AgentSlashCommandSuggestion.command(named: "model", in: commands))
        XCTAssertNil(AgentSlashCommandSuggestion.command(named: "browser", in: commands))
    }
}
