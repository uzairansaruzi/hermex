import Foundation

/// Everything the popover draws for one query.
struct SlashAutocompleteResults: Equatable, Sendable {
    /// The pass that produced these rows. Comparing it against the current pass
    /// is how the view knows whether they still describe what the user typed.
    var input: SlashAutocompleteRanking
    var commands: [SlashCommand] = []
    var skills: [SkillSlashSuggestion] = []
    var agentCommands: [AgentSlashCommandSuggestion] = []
    var skillSubArgs: [SkillSlashSuggestion] = []

    var commandRowCount: Int {
        commands.count + skills.count + agentCommands.count
    }

    var hasNoCommandRows: Bool {
        commandRowCount == 0
    }
}

/// The inputs one ranking pass needs. Held as a value so the view can hand it to
/// `.task(id:)` and, for a large catalog, to a background task.
struct SlashAutocompleteRanking: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// The `/` trigger at the start of the draft: built-in commands, skills,
        /// and agent commands.
        case commands
        /// The `/` trigger mid-sentence, where only a skill can work.
        case skillsOnly
        /// The `/skills <query>` trigger.
        case skillSubArgs
        /// A sub-argument list that filters synchronously and needs no ranking.
        case inactive
    }

    /// Up to this many candidates, ranking costs microseconds and belongs
    /// inline; past it the work is worth a hop off the main actor.
    private static let inlineRankingLimit = 128

    let mode: Mode
    let query: String
    let skills: [SkillSlashSuggestion]
    let agentCommands: [AgentCommand]
    /// The app's own commands, listed first (`SlashCommandScope.builtins`).
    var builtins = SlashCommandCatalog.allCommands
    /// Whether an agent command's aliases find it, as in a Hermes chat (#1036).
    var matchesAliases = false

    /// True when this pass is cheap enough to run wherever it is asked for.
    var ranksInline: Bool {
        skills.count + agentCommands.count <= Self.inlineRankingLimit
    }

    /// Ranks off the main actor once the catalog is big enough for the work to
    /// show up as typing lag.
    func rankedResults() async -> SlashAutocompleteResults {
        guard !ranksInline else { return results() }

        return await Task.detached(priority: .userInitiated) { results() }.value
    }

    func results() -> SlashAutocompleteResults {
        switch mode {
        case .inactive:
            return SlashAutocompleteResults(input: self)
        case .skillSubArgs:
            return SlashAutocompleteResults(
                input: self,
                skillSubArgs: SlashSkillFormatter.matching(query, in: skills)
            )
        case .skillsOnly:
            return SlashAutocompleteResults(
                input: self,
                skills: SlashSkillFormatter.matching(query, in: skills)
            )
        case .commands:
            let skillNames = Set(skills.map { $0.slashName.lowercased() })
            let builtinNames = Set(builtins.map { $0.name.lowercased() })
            return SlashAutocompleteResults(
                input: self,
                commands: SlashCommandCatalog.matching(query, in: builtins),
                skills: SlashSkillFormatter.matching(query, in: skills),
                agentCommands: AgentSlashCommandSuggestion.matching(
                    query,
                    in: agentCommands,
                    excluding: builtinNames.union(skillNames),
                    matchingAliases: matchesAliases
                )
            )
        }
    }
}

struct AgentSlashCommandSuggestion: Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    let argHint: String?
    let aliases: [String]

    /// The server's own description, or `nil`. Ranking uses this rather than
    /// `description` so the "Agent command" placeholder, which every command
    /// without a description shares, never matches a query.
    private let serverDescription: String?

    var id: String { name.lowercased() }

    init?(_ command: AgentCommand) {
        guard command.cliOnly != true,
              command.gatewayOnly != true,
              let name = Self.nonEmpty(command.name)
        else {
            return nil
        }

        self.name = name
        serverDescription = Self.nonEmpty(command.description)
        description = serverDescription ?? String(localized: "Agent command")
        argHint = Self.nonEmpty(command.argsHint)
        aliases = command.aliases ?? []
    }

    /// The agent commands worth showing for `query`, best first, skipping any
    /// name in `excludedNames` and any duplicate. `matchingAliases` ranks each
    /// command by its best name or alias, so `/ctx` finds `/context` (#1036).
    static func matching(
        _ query: String,
        in commands: [AgentCommand],
        excluding excludedNames: Set<String> = [],
        matchingAliases: Bool = false,
        limit: Int = SlashCommandRanker.resultLimit
    ) -> [AgentSlashCommandSuggestion] {
        var seen = excludedNames
        var candidates: [AgentSlashCommandSuggestion] = []

        for command in commands {
            guard let suggestion = AgentSlashCommandSuggestion(command) else { continue }
            guard seen.insert(suggestion.id).inserted else { continue }
            candidates.append(suggestion)
        }

        guard matchingAliases, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SlashCommandRanker.rank(candidates, matching: query, limit: limit) { suggestion in
                SlashRankableFields(name: suggestion.name, description: suggestion.serverDescription)
            }
        }

        // One entry per name and alias, then each command once, at its best entry.
        let entries = candidates.flatMap { suggestion in
            ([suggestion.name] + suggestion.aliases).map { (suggestion: suggestion, name: $0) }
        }
        let ranked = SlashCommandRanker.rank(entries, matching: query, limit: entries.count) { entry in
            SlashRankableFields(name: entry.name, description: entry.suggestion.serverDescription)
        }
        var listed = Set<String>()
        var results: [AgentSlashCommandSuggestion] = []
        for entry in ranked where results.count < limit && listed.insert(entry.suggestion.id).inserted {
            results.append(entry.suggestion)
        }
        return results
    }

    static func command(named name: String, in commands: [AgentCommand]) -> AgentSlashCommandSuggestion? {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        guard SlashCommandCatalog.command(named: lower) == nil else { return nil }

        return commands.lazy.compactMap(AgentSlashCommandSuggestion.init).first { suggestion in
            suggestion.name.lowercased() == lower
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
