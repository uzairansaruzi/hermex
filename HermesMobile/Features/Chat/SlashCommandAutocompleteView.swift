import SwiftUI

struct SlashCommandAutocompleteView: View {
    // Row height tracks Dynamic Type so the panel is never taller or shorter
    // than the rows it actually draws.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .subheadline) private var emptyPanelHeight: CGFloat = 64
    private let maxPanelHeight: CGFloat = 280

    let query: String
    let selectedModelID: String?
    let modelGroups: [ModelCatalogGroup]
    let workspaceRoots: [WorkspaceRoot]
    let workspaceSuggestions: [String]
    let personalitySuggestions: [String]
    let skillSuggestions: [SkillSlashSuggestion]
    let agentCommands: [AgentCommand]
    let selectedReasoningEffort: String?
    let onSelectCommand: (SlashCommand) -> Void
    let onSelectSkillCommand: (SkillSlashSuggestion) -> Void
    let onSelectAgentCommand: (AgentSlashCommandSuggestion) -> Void
    let onSelectSkillSubArg: (SkillSlashSuggestion) -> Void
    let onSelectSubArg: (String) -> Void
    let onDismiss: () -> Void

    /// The last completed background ranking pass, or `nil` before the first one lands.
    @State private var cachedResults: SlashAutocompleteResults?

    private var parsed: ParsedSlashQuery {
        ParsedSlashQuery(query: query)
    }

    var body: some View {
        let parsed = parsed
        let results = currentResults

        VStack(spacing: 0) {
            if parsed.isSubArgMode, let command = parsed.command {
                subArgList(for: command, results: results)
            } else {
                commandList(results)
            }
        }
        .adaptiveGlass(
            .regular,
            fallbackMaterial: .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 12, y: 4)
        .frame(height: panelHeight(for: results, parsed: parsed))
        .task(id: rankingInput) {
            let ranked = await rankingInput.rankedResults()
            // A background pass does not inherit this task's cancellation, so
            // one started for an older query can still finish last. Drop it
            // rather than let it overwrite newer rows.
            guard !Task.isCancelled else { return }
            cachedResults = ranked
        }
    }

    /// The results to draw. A pass ranked for a different trigger is never read
    /// back, and on the first frame there is no pass yet; both cases rank inline
    /// so the panel opens at its real height instead of popping out of an empty
    /// box. Every keystroke after that stays on the same trigger and reads what
    /// the background pass left here.
    private var currentResults: SlashAutocompleteResults {
        let input = rankingInput
        if let cachedResults, cachedResults.mode == input.mode { return cachedResults }
        return input.results()
    }

    private var rankingInput: SlashAutocompleteRanking {
        let parsed = parsed
        guard parsed.isSubArgMode, let command = parsed.command else {
            return SlashAutocompleteRanking(
                mode: .commands,
                query: parsed.commandName,
                skills: skillSuggestions,
                agentCommands: agentCommands
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
        return min(maxPanelHeight, CGFloat(rowCount) * rowHeight)
    }

    private func visibleRowCount(for results: SlashAutocompleteResults, parsed: ParsedSlashQuery) -> Int {
        if parsed.isSubArgMode, let command = parsed.command {
            if command.subArgs == .skills {
                return results.skillSubArgs.count
            }
            return filteredSubArgs(for: command).count
        }

        return results.commandRowCount
    }

    @ViewBuilder
    private func commandList(_ results: SlashAutocompleteResults) -> some View {
        if results.hasNoCommandRows {
            Text("No commands or skills match \"\(parsed.commandName)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        } else {
            let commands = results.commands
            let skills = results.skills
            let agentCommands = results.agentCommands

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        commandRow(command)

                        if index < commands.count - 1 || !skills.isEmpty || !agentCommands.isEmpty {
                            rowDivider
                        }
                    }

                    ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                        skillRow(skill)

                        if index < skills.count - 1 || !agentCommands.isEmpty {
                            rowDivider
                        }
                    }

                    ForEach(Array(agentCommands.enumerated()), id: \.element.id) { index, command in
                        agentCommandRow(command)

                        if index < agentCommands.count - 1 {
                            rowDivider
                        }
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

    /// How a row renders its name and hint. Commands are typed literally, so
    /// they are monospaced; a skill's category is prose.
    private enum RowStyle {
        case command
        case skill
        case skillName

        var nameFont: Font {
            switch self {
            case .command, .skill:
                return .system(.subheadline, design: .monospaced).weight(.semibold)
            case .skillName:
                return Font.subheadline.weight(.semibold)
            }
        }

        var hintFont: Font {
            switch self {
            case .command:
                return .system(.footnote, design: .monospaced)
            case .skill, .skillName:
                return .footnote
            }
        }
    }

    /// One autocomplete row: the thing you type, then its supporting copy on the
    /// same line. The name keeps its width and the detail truncates.
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }

            Text(name)
                .font(style.nameFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(2)

            if let hint {
                Text(hint)
                    .font(style.hintFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var rowDivider: some View {
        Divider()
            .padding(.horizontal, 16)
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, skill in
                        skillSubArgRow(skill)

                        if index < filtered.count - 1 {
                            rowDivider
                        }
                    }
                }
            }
        }
    }

    /// The skill trigger says why it is empty: no catalog at all reads
    /// differently from a query nothing matched.
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { index, item in
                        Button {
                            onSelectSubArg(item)
                        } label: {
                            HStack(spacing: 12) {
                                Text(subArgDisplayText(item, for: command))
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer(minLength: 0)

                                if command.subArgs == .models,
                                   item == selectedModelID {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }

                                if command.subArgs == .reasoningLevels,
                                   item == selectedReasoningEffort {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < filtered.count - 1 {
                            Divider()
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
    }

    private func subArgs(for command: SlashCommand) -> [String] {
        switch command.subArgs {
        case .models:
            let allModels = modelGroups.flatMap(\.allModels).map(\.id)
            // Deduplicate while preserving order
            var seen = Set<String>()
            return allModels.filter { seen.insert($0).inserted }
        case .workspaces:
            let roots = workspaceRoots.compactMap(\.path)
            let suggestions = workspaceSuggestions
            var seen = Set<String>()
            return (roots + suggestions).filter { seen.insert($0).inserted }
        case .reasoningLevels:
            return SlashCommandCatalog.reasoningLevels
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
        guard let command = SlashCommandCatalog.command(named: commandName) else { return false }
        guard command.subArgs != .none else { return false }
        let prefix = "/\(command.name)"
        guard query.hasPrefix(prefix) else { return false }
        let afterCommand = String(query.dropFirst(prefix.count))
        return afterCommand.hasPrefix(" ")
    }

    var command: SlashCommand? {
        SlashCommandCatalog.command(named: commandName)
    }
}
