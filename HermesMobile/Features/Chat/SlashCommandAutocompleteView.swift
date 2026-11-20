import SwiftUI

struct SlashCommandAutocompleteView: View {
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .subheadline) private var emptyPanelHeight: CGFloat = 64

    let query: String
    let selectedModelID: String?
    let modelGroups: [ModelCatalogGroup]
    let workspaceRoots: [WorkspaceRoot]
    let workspaceSuggestions: [String]
    let personalitySuggestions: [String]
    let skillSuggestions: [SkillSlashSuggestion]
    let agentCommands: [AgentCommand]
    let skillsOnly: Bool
    let selectedReasoningEffort: String?
    var scope: SlashCommandScope = .webui
    var reasoningLevels = SlashCommandCatalog.reasoningLevels
    var hostCompletion: HermesSlashCompletion?
    let onSelectCommand: (SlashCommand) -> Void
    let onSelectSkillCommand: (SkillSlashSuggestion) -> Void
    let onSelectAgentCommand: (AgentSlashCommandSuggestion) -> Void
    let onSelectSkillSubArg: (SkillSlashSuggestion) -> Void
    let onSelectSubArg: (String) -> Void
    var onSelectHostArgument: (HermesSlashCompletion.Item) -> Void = { _ in }

    @State private var cachedResults: SlashAutocompleteResults?

    private var parsed: ParsedSlashQuery {
        ParsedSlashQuery(query: query, scope: scope)
    }

    var body: some View {
        let parsed = parsed
        let results = currentResults

        VStack(spacing: 0) {
            if parsed.isSubArgMode, let command = parsed.command {
                subArgList(for: command, results: results)
            } else if parsed.isHostArgumentMode {
                hostArgumentList(hostCompletion?.items ?? [])
            } else {
                commandList(results)
            }
        }
        .adaptiveGlass(
            .regular,
            fallbackMaterial: .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 12, y: 4)
        .composerPanelHeight(panelHeight(for: results, parsed: parsed))
        .task(id: rankingInput) {
            let ranked = await rankingInput.rankedResults()
            guard !Task.isCancelled else { return }
            cachedResults = ranked
        }
    }

    private var currentResults: SlashAutocompleteResults {
        let input = rankingInput

        if let cachedResults {
            if cachedResults.input == input { return cachedResults }
            if !input.ranksInline, cachedResults.input.mode == input.mode { return cachedResults }
        }

        return input.results()
    }

    private var rankingInput: SlashAutocompleteRanking {
        let parsed = parsed

        if skillsOnly {
            return SlashAutocompleteRanking(
                mode: .skillsOnly,
                query: parsed.commandName,
                skills: skillSuggestions,
                agentCommands: []
            )
        }

        guard parsed.isSubArgMode, let command = parsed.command else {
            return SlashAutocompleteRanking(
                mode: parsed.isHostArgumentMode ? .inactive : .commands,
                query: parsed.commandName,
                skills: skillSuggestions,
                agentCommands: agentCommands,
                builtins: scope.builtins,
                matchesAliases: scope.isHermes
            )
        }

        guard command.subArgs == .skills else {
            return SlashAutocompleteRanking(mode: .inactive, query: "", skills: [], agentCommands: [])
        }

        return SlashAutocompleteRanking(
            mode: .skillSubArgs,
            query: SlashSkillFormatter.skillQuery(from: parsed.argQuery),
            skills: skillSuggestions,
            agentCommands: []
        )
    }

    private func panelHeight(for results: SlashAutocompleteResults, parsed: ParsedSlashQuery) -> CGFloat {
        let rowCount = visibleRowCount(for: results, parsed: parsed)
        guard rowCount > 0 else { return emptyPanelHeight }
        return CGFloat(rowCount) * rowHeight
    }

    private func visibleRowCount(for results: SlashAutocompleteResults, parsed: ParsedSlashQuery) -> Int {
        if parsed.isSubArgMode, let command = parsed.command {
            if command.subArgs == .skills {
                return results.skillSubArgs.count
            }
            return filteredSubArgs(for: command).count
        }
        if parsed.isHostArgumentMode {
            return hostCompletion?.items.count ?? 0
        }

        return results.commandRowCount
    }

    @ViewBuilder
    private func commandList(_ results: SlashAutocompleteResults) -> some View {
        if results.hasNoCommandRows {
            Text("No commands or skills match \"\(parsed.commandName)\"")
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        } else {
            let commands = results.commands
            let skills = results.skills
            let agentCommands = results.agentCommands

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(commands, id: \.id) { command in
                        commandRow(command)
                    }

                    ForEach(skills, id: \.id) { skill in
                        skillRow(skill)
                    }

                    ForEach(agentCommands, id: \.id) { command in
                        agentCommandRow(command)
                    }
                }
            }
        }
    }

    private func commandRow(_ command: SlashCommand) -> some View {
        Button {
            onSelectCommand(command)
        } label: {
            rowContent(
                name: "/\(command.name)",
                hint: command.argHint,
                detail: command.description,
                style: .command
            )
        }
        .buttonStyle(.plain)
    }

    private func agentCommandRow(_ command: AgentSlashCommandSuggestion) -> some View {
        Button {
            onSelectAgentCommand(command)
        } label: {
            rowContent(
                name: "/\(command.name)",
                hint: command.argHint,
                detail: command.description,
                style: .command
            )
        }
        .buttonStyle(.plain)
    }

    private func skillRow(_ skill: SkillSlashSuggestion) -> some View {
        Button {
            onSelectSkillCommand(skill)
        } label: {
            rowContent(
                name: "/\(skill.slashName)",
                hint: skill.category,
                detail: skill.description ?? String(localized: "Skill"),
                style: .skill,
                icon: "bolt.fill"
            )
        }
        .buttonStyle(.plain)
    }

    private func skillSubArgRow(_ skill: SkillSlashSuggestion) -> some View {
        Button {
            onSelectSkillSubArg(skill)
        } label: {
            rowContent(
                name: skill.name,
                hint: skill.category,
                detail: skill.description ?? String(localized: "Skill"),
                style: .skillName
            )
        }
        .buttonStyle(.plain)
    }

    private enum RowStyle {
        case command
        case skill
        case skillName

        var nameFont: Font {
            switch self {
            case .command, .skill:
                return .system(.subheadline, design: .monospaced).weight(.semibold)
            case .skillName:
                return AppFont.subheadline(weight: .semibold)
            }
        }

        var hintFont: Font {
            switch self {
            case .command:
                return .system(.footnote, design: .monospaced)
            case .skill, .skillName:
                return AppFont.footnote()
            }
        }
    }

    private func rowContent(
        name: String,
        hint: String?,
        detail: String,
        style: RowStyle,
        icon: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(AppFont.caption2(weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }

            Text(name)
                .font(style.nameFont)
                .foregroundStyle(.appPrimary)
                .lineLimit(1)
                .layoutPriority(2)

            if let hint {
                Text(hint)
                    .font(style.hintFont)
                    .foregroundStyle(.appSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            Text(detail)
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }


    @ViewBuilder
    private func subArgList(for command: SlashCommand, results: SlashAutocompleteResults) -> some View {
        if command.subArgs == .skills {
            skillSubArgList(results.skillSubArgs)
        } else {
            standardSubArgList(for: command)
        }
    }

    @ViewBuilder
    private func skillSubArgList(_ filtered: [SkillSlashSuggestion]) -> some View {
        if filtered.isEmpty {
            skillSubArgEmptyText
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.id) { skill in
                        skillSubArgRow(skill)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var skillSubArgEmptyText: some View {
        if skillSuggestions.isEmpty {
            Text("No skills are configured on the server.")
        } else {
            Text("No skills match \"\(skillSubArgQuery)\".")
        }
    }

    @ViewBuilder
    private func standardSubArgList(for command: SlashCommand) -> some View {
        let filtered = filteredSubArgs(for: command)

        if filtered.isEmpty {
            Text("No matches for \"\(parsed.argQuery)\"")
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, item in
                        Button {
                            onSelectSubArg(item)
                        } label: {
                            HStack(spacing: 12) {
                                Text(subArgDisplayText(item, for: command))
                                    .font(AppFont.subheadline())
                                    .foregroundStyle(.appPrimary)
                                    .lineLimit(1)

                                Spacer(minLength: 0)

                                if command.subArgs == .models,
                                   item == selectedModelID {
                                    Image(systemName: "checkmark")
                                        .font(AppFont.caption())
                                        .foregroundStyle(Color.accentColor)
                                }

                                if command.subArgs == .reasoningLevels,
                                   item == selectedReasoningEffort {
                                    Image(systemName: "checkmark")
                                        .font(AppFont.caption())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func subArgs(for command: SlashCommand) -> [String] {
        switch command.subArgs {
        case .models:
            let allModels = modelGroups.flatMap(\.allModels).map(\.id)
            var seen = Set<String>()
            return allModels.filter { seen.insert($0).inserted }
        case .workspaces:
            let roots = workspaceRoots.compactMap(\.path)
            let suggestions = workspaceSuggestions
            var seen = Set<String>()
            return (roots + suggestions).filter { seen.insert($0).inserted }
        case .reasoningLevels:
            return reasoningLevels
        case .personalities:
            return personalitySuggestions
        case .skills:
            return skillSuggestions.map(\.slashName)
        case .goalActions:
            return SlashCommandCatalog.goalActions
        case .none:
            return []
        }
    }

    private func hostArgumentList(_ items: [HermesSlashCompletion.Item]) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        onSelectHostArgument(item)
                    } label: {
                        rowContent(name: item.display, hint: nil, detail: item.meta, style: .command)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func subArgDisplayText(_ item: String, for command: SlashCommand) -> String {
        command.subArgs == .goalActions ? "/\(command.name) \(item)" : item
    }

    private func filteredSubArgs(for command: SlashCommand) -> [String] {
        subArgs(for: command).filter {
            parsed.argQuery.isEmpty || $0.lowercased().hasPrefix(parsed.argQuery.lowercased())
        }
    }

    private var skillSubArgQuery: String {
        SlashSkillFormatter.skillQuery(from: parsed.argQuery)
    }
}

struct ParsedSlashQuery {
    let query: String
    var scope: SlashCommandScope = .webui

    var commandName: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return trimmed }
        let withoutSlash = String(trimmed.dropFirst())
        let components = withoutSlash.split(separator: " ", maxSplits: 1)
        return String(components.first ?? "")
    }

    var argQuery: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return "" }
        let withoutSlash = String(trimmed.dropFirst())
        let components = withoutSlash.split(separator: " ", maxSplits: 1)
        guard components.count > 1 else { return "" }
        return String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSubArgMode: Bool {
        guard let command, command.subArgs != .none else { return false }
        return hasArgument(after: commandName)
    }

    var isHostArgumentMode: Bool {
        command == nil && scope.completesOnHost(commandName) && hasArgument(after: commandName)
    }

    var command: SlashCommand? {
        scope.command(named: commandName)
    }

    private func hasArgument(after name: String) -> Bool {
        let prefix = "/\(name)"
        guard query.hasPrefix(prefix) else { return false }
        return query.dropFirst(prefix.count).hasPrefix(" ")
    }
}
