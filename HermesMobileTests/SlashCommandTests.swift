import XCTest
@testable import HermesMobile

final class SlashCommandTests: XCTestCase {

    // MARK: - Catalog matching

    func testMatchingEmptyQueryReturnsAllCommands() {
        let results = SlashCommandCatalog.matching("")
        XCTAssertEqual(results.count, SlashCommandCatalog.allCommands.count)
    }

    func testMatchingByPrefix() {
        let results = SlashCommandCatalog.matching("mod")
        XCTAssertTrue(results.contains { $0.name == "model" })
    }

    func testMatchingByDescription() {
        let results = SlashCommandCatalog.matching("clear")
        XCTAssertTrue(results.contains { $0.name == "clear" })
    }

    func testMatchingIsCaseInsensitive() {
        let lower = SlashCommandCatalog.matching("model")
        let upper = SlashCommandCatalog.matching("MODEL")
        XCTAssertEqual(lower.count, upper.count)
        XCTAssertEqual(lower.first?.name, upper.first?.name)
    }

    func testNoMatchReturnsEmpty() {
        let results = SlashCommandCatalog.matching("xyznonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    func testCommandNamedReturnsCorrectCommand() {
        let command = SlashCommandCatalog.command(named: "help")
        XCTAssertEqual(command?.name, "help")
        XCTAssertEqual(command?.handler, .clientSide(.help))
    }

    func testBranchCommandIsMobileSafeAdvancedCommand() {
        let command = SlashCommandCatalog.command(named: "branch")
        XCTAssertEqual(command?.name, "branch")
        XCTAssertEqual(command?.handler, .serverSide(.branch))
        XCTAssertEqual(command?.noEcho, true)

        let alias = SlashCommandCatalog.command(named: "fork")
        XCTAssertEqual(alias?.handler, .serverSide(.branch))
        XCTAssertEqual(alias?.noEcho, true)
        XCTAssertEqual(alias?.argHint, "name")
    }

    func testUndoCommandIsMobileSafeAdvancedCommand() {
        let command = SlashCommandCatalog.command(named: "undo")
        XCTAssertEqual(command?.name, "undo")
        XCTAssertEqual(command?.handler, .serverSide(.undo))
        XCTAssertEqual(command?.noEcho, true)
    }

    func testRetryCommandIsMobileSafeAdvancedCommand() {
        let command = SlashCommandCatalog.command(named: "retry")
        XCTAssertEqual(command?.name, "retry")
        XCTAssertEqual(command?.handler, .serverSide(.retry))
        XCTAssertEqual(command?.noEcho, true)
    }

    func testCompressCommandIsMobileSafeAdvancedCommand() {
        let command = SlashCommandCatalog.command(named: "compress")
        XCTAssertEqual(command?.name, "compress")
        XCTAssertEqual(command?.handler, .serverSide(.compress))
        XCTAssertEqual(command?.noEcho, true)
        XCTAssertEqual(command?.argHint, "focus topic")

        let alias = SlashCommandCatalog.command(named: "compact")
        XCTAssertEqual(alias?.handler, .serverSide(.compress))
        XCTAssertEqual(alias?.noEcho, true)
        XCTAssertEqual(alias?.argHint, "focus topic")
    }

    func testSkillsCommandIsMobileSafeSearchCommand() {
        let command = SlashCommandCatalog.command(named: "skills")
        XCTAssertEqual(command?.name, "skills")
        XCTAssertEqual(command?.handler, .serverSide(.skills))
        XCTAssertEqual(command?.noEcho, false)
        XCTAssertEqual(command?.argHint, "query")
        XCTAssertEqual(command?.subArgs, .skills)
    }

    func testBusyInputCommandsAreMobileSafeCommands() {
        let queue = SlashCommandCatalog.command(named: "queue")
        XCTAssertEqual(queue?.handler, .serverSide(.queue))
        XCTAssertEqual(queue?.noEcho, true)
        XCTAssertEqual(queue?.argHint, "message")

        let steer = SlashCommandCatalog.command(named: "steer")
        XCTAssertEqual(steer?.handler, .serverSide(.steer))
        XCTAssertEqual(steer?.noEcho, true)
        XCTAssertEqual(steer?.argHint, "message")

        let interrupt = SlashCommandCatalog.command(named: "interrupt")
        XCTAssertEqual(interrupt?.handler, .serverSide(.interrupt))
        XCTAssertEqual(interrupt?.noEcho, true)
        XCTAssertEqual(interrupt?.argHint, "message")

        let status = SlashCommandCatalog.command(named: "status")
        XCTAssertEqual(status?.handler, .serverSide(.status))
        XCTAssertEqual(status?.noEcho, false)
        XCTAssertNil(status?.argHint)
    }

    func testGoalCommandIsMobileSafePersistentGoalCommand() {
        let command = SlashCommandCatalog.command(named: "goal")
        XCTAssertEqual(command?.name, "goal")
        XCTAssertEqual(command?.handler, .serverSide(.goal))
        XCTAssertEqual(command?.noEcho, true)
        XCTAssertEqual(command?.argHint, "[status|pause|resume|clear|text]")
        XCTAssertEqual(command?.subArgs, .goalActions)
        XCTAssertEqual(SlashCommandCatalog.goalActions, ["status", "pause", "resume", "clear"])
    }

    func testSideTaskCommandsAreMobileSafeCommands() {
        let btw = SlashCommandCatalog.command(named: "btw")
        XCTAssertEqual(btw?.handler, .serverSide(.btw))
        XCTAssertEqual(btw?.noEcho, true)
        XCTAssertEqual(btw?.argHint, "question")

        let background = SlashCommandCatalog.command(named: "background")
        XCTAssertEqual(background?.handler, .serverSide(.background))
        XCTAssertEqual(background?.noEcho, true)
        XCTAssertEqual(background?.argHint, "prompt")

        let alias = SlashCommandCatalog.command(named: "bg")
        XCTAssertEqual(alias?.handler, .serverSide(.background))
        XCTAssertEqual(alias?.noEcho, true)
        XCTAssertEqual(alias?.argHint, "prompt")
    }

    func testMatchingFindsUnsupportedCommands() {
        XCTAssertTrue(SlashCommandCatalog.matching("que").contains { $0.name == "queue" })
        XCTAssertTrue(SlashCommandCatalog.matching("ste").contains { $0.name == "steer" })
        XCTAssertTrue(SlashCommandCatalog.matching("int").contains { $0.name == "interrupt" })
        XCTAssertTrue(SlashCommandCatalog.matching("sta").contains { $0.name == "status" })
        XCTAssertTrue(SlashCommandCatalog.matching("bt").contains { $0.name == "btw" })
        XCTAssertTrue(SlashCommandCatalog.matching("back").contains { $0.name == "background" })
        XCTAssertTrue(SlashCommandCatalog.matching("bg").contains { $0.name == "bg" })
        XCTAssertTrue(SlashCommandCatalog.matching("com").contains { $0.name == "compact" })
        XCTAssertTrue(SlashCommandCatalog.matching("for").contains { $0.name == "fork" })
        XCTAssertTrue(SlashCommandCatalog.matching("goa").contains { $0.name == "goal" })
    }

    func testCommandNamedIsCaseInsensitive() {
        let lower = SlashCommandCatalog.command(named: "model")
        let upper = SlashCommandCatalog.command(named: "MODEL")
        XCTAssertEqual(lower?.name, upper?.name)
    }

    func testCommandNamedReturnsNilForUnknown() {
        XCTAssertNil(SlashCommandCatalog.command(named: "nope"))
    }

    // MARK: - Reasoning levels

    func testReasoningLevelsContainsExpectedValues() {
        let levels = SlashCommandCatalog.reasoningLevels
        XCTAssertTrue(levels.contains("show"))
        XCTAssertTrue(levels.contains("hide"))
        XCTAssertTrue(levels.contains("none"))
        XCTAssertTrue(levels.contains("minimal"))
        XCTAssertTrue(levels.contains("low"))
        XCTAssertTrue(levels.contains("medium"))
        XCTAssertTrue(levels.contains("high"))
        XCTAssertTrue(levels.contains("xhigh"))
    }

    // MARK: - ParsedSlashQuery

    func testParsedQueryExtractsCommandName() {
        let parsed = ParsedSlashQuery(query: "/model gpt-4")
        XCTAssertEqual(parsed.commandName, "model")
    }

    func testParsedQueryExtractsArgQuery() {
        let parsed = ParsedSlashQuery(query: "/model gpt-4")
        XCTAssertEqual(parsed.argQuery, "gpt-4")
    }

    func testParsedQueryNoArgs() {
        let parsed = ParsedSlashQuery(query: "/help")
        XCTAssertEqual(parsed.commandName, "help")
        XCTAssertEqual(parsed.argQuery, "")
    }

    func testParsedQueryMultipleSpaces() {
        let parsed = ParsedSlashQuery(query: "/model   gpt-4")
        XCTAssertEqual(parsed.commandName, "model")
        XCTAssertEqual(parsed.argQuery, "gpt-4")
    }

    func testParsedQueryIsSubArgModeForModels() {
        let parsed = ParsedSlashQuery(query: "/model g")
        XCTAssertTrue(parsed.isSubArgMode)
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

    func testParsedQueryReturnsCommand() {
        let parsed = ParsedSlashQuery(query: "/model gpt-4")
        XCTAssertEqual(parsed.command?.name, "model")
    }

    func testParsedQueryTreatsGoalActionsAsSubArgs() {
        let parsed = ParsedSlashQuery(query: "/goal sta")
        XCTAssertEqual(parsed.command?.name, "goal")
        XCTAssertEqual(parsed.command?.subArgs, .goalActions)
        XCTAssertEqual(parsed.argQuery, "sta")
        XCTAssertTrue(parsed.isSubArgMode)
    }

    func testParsedQueryReturnsNilCommandForUnknown() {
        let parsed = ParsedSlashQuery(query: "/nope")
        XCTAssertNil(parsed.command)
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

    func testSkillMatchingFindsPartialSkillName() {
        let suggestions = SlashSkillFormatter.suggestions(from: [
            SkillSummary(name: "claude-code", category: "coding", description: "Use Claude Code", path: nil),
            SkillSummary(name: "swift-refactor", category: "coding", description: "Refactor Swift", path: nil)
        ])

        XCTAssertEqual(SlashSkillFormatter.matching("claude", in: suggestions).map(\.name), ["claude-code"])
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

    func testSkillMessageGroupsByCategory() {
        let suggestions = SlashSkillFormatter.suggestions(from: [
            SkillSummary(name: "swift-refactor", category: "coding", description: "Refactor Swift", path: nil),
            SkillSummary(name: "doc-search", category: "research", description: nil, path: nil)
        ])

        let message = SlashSkillFormatter.message(for: suggestions, query: "")
        XCTAssertTrue(message.contains("Available skills:"))
        XCTAssertTrue(message.contains("### coding"))
        XCTAssertTrue(message.contains("- `swift-refactor` - **swift-refactor** - Refactor Swift"))
        XCTAssertTrue(message.contains("### research"))
        XCTAssertTrue(message.contains("- `doc-search` - **doc-search**"))
    }

    func testSkillDetailMessageShowsSingleSkillUsage() {
        let skill = SkillSlashSuggestion(
            name: "Spotify",
            category: "media",
            description: "Control Spotify playback."
        )

        let message = SlashSkillFormatter.detailMessage(for: skill)

        XCTAssertTrue(message.contains("### `/spotify`"))
        XCTAssertTrue(message.contains("**Spotify**"))
        XCTAssertTrue(message.contains("Category: media"))
        XCTAssertTrue(message.contains("Control Spotify playback."))
        XCTAssertTrue(message.contains("Send `/spotify <message>` to use this skill."))
    }

    // MARK: - Agent slash suggestions

    func testAgentCommandSuggestionsIncludeNonCLICommands() {
        let suggestions = AgentSlashCommandSuggestion.matching("res", in: [
            AgentCommand(
                name: "resume",
                description: "Resume a previously-named session",
                argsHint: "name",
                cliOnly: false,
                gatewayOnly: false
            )
        ])

        XCTAssertEqual(suggestions.map(\.name), ["resume"])
        XCTAssertEqual(suggestions.first?.description, "Resume a previously-named session")
        XCTAssertEqual(suggestions.first?.argHint, "name")
    }

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

    func testScoreStaggersLabelAndDescriptionFields() {
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", label: "review"), matching: "review"), 1)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", label: "review"), matching: "rev"), 3)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", label: "code-review"), matching: "review"), 5)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", label: "code review"), matching: "eview"), 7)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", label: "review"), matching: "rvw"), 110)

        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", shortDescription: "coding"), matching: "coding"), 20)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", shortDescription: "coding"), matching: "cod"), 22)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", shortDescription: "fast-coding"), matching: "coding"), 24)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", shortDescription: "coding"), matching: "oding"), 26)

        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", description: "refactor"), matching: "refactor"), 30)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", description: "refactor"), matching: "ref"), 32)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", description: "swift/refactor"), matching: "refactor"), 34)
        XCTAssertEqual(SlashCommandRanker.score(fields(name: "n", description: "refactor"), matching: "efactor"), 36)
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

    func testCatalogMatchingPrefersNamesOverDescriptions() {
        let results = SlashCommandCatalog.matching("stop")
        XCTAssertEqual(results.first?.name, "stop")
        // `/interrupt` only mentions "Stop" in its description, so it ranks below.
        XCTAssertTrue(results.contains { $0.name == "interrupt" })
    }

    func testCatalogMatchingIsBounded() {
        XCTAssertLessThanOrEqual(SlashCommandCatalog.matching("s").count, SlashCommandRanker.resultLimit)
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
