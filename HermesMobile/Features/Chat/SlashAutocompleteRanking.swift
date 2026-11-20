import Foundation

struct SlashAutocompleteResults: Equatable, Sendable {
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

struct SlashAutocompleteRanking: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case commands
        case skillsOnly
        case skillSubArgs
        case inactive
    }

    private static let inlineRankingLimit = 128

    let mode: Mode
    let query: String
    let skills: [SkillSlashSuggestion]
    let agentCommands: [AgentCommand]
    var builtins = SlashCommandCatalog.allCommands
    var matchesAliases = false

    var ranksInline: Bool {
        skills.count + agentCommands.count <= Self.inlineRankingLimit
    }

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
