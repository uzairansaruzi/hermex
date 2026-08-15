import SwiftUI

struct SlashCommandAutocompleteView: View {
    private let rowHeight: CGFloat = 48
    private let emptyPanelHeight: CGFloat = 64
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

    private var parsed: ParsedSlashQuery {
        ParsedSlashQuery(query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            if parsed.isSubArgMode, let command = parsed.command {
                subArgList(for: command)
            } else {
                commandList
            }
        }
        .adaptiveGlass(
            .regular,
            fallbackMaterial: .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 12, y: 4)
        .frame(height: panelHeight)
    }

    private var panelHeight: CGFloat {
        let rowCount = visibleRowCount
        guard rowCount > 0 else { return emptyPanelHeight }
        return min(maxPanelHeight, CGFloat(rowCount) * rowHeight)
    }

    private var visibleRowCount: Int {
        if parsed.isSubArgMode, let command = parsed.command {
            if command.subArgs == .skills {
                return filteredSkillSubArgSuggestions.count
            }
            return filteredSubArgs(for: command).count
        }

        return SlashCommandCatalog.matching(parsed.commandName).count +
            filteredSkillSuggestions.count +
            filteredAgentCommandSuggestions.count
    }

    @ViewBuilder
    private var commandList: some View {
        let commands = SlashCommandCatalog.matching(parsed.commandName)
        let skills = filteredSkillSuggestions
        let agentCommands = filteredAgentCommandSuggestions
        if commands.isEmpty && skills.isEmpty && agentCommands.isEmpty {
            Text("No commands or skills match \"\(parsed.commandName)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        } else {
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
            HStack(spacing: 12) {
                Text("/\(command.name)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                if let argHint = command.argHint {
                    Text(argHint)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(command.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func agentCommandRow(_ command: AgentSlashCommandSuggestion) -> some View {
        Button {
            onSelectAgentCommand(command)
        } label: {
            HStack(spacing: 12) {
                Text("/\(command.name)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let argHint = command.argHint {
                    Text(argHint)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(command.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func skillRow(_ skill: SkillSlashSuggestion) -> some View {
        Button {
            onSelectSkillCommand(skill)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 12)
                    .accessibilityHidden(true)

                Text("/\(skill.slashName)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let category = skill.category {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(skill.description ?? String(localized: "Skill"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func subArgList(for command: SlashCommand) -> some View {
        if command.subArgs == .skills {
            skillSubArgList
        } else {
            standardSubArgList(for: command)
        }
    }

    @ViewBuilder
    private var skillSubArgList: some View {
        let filtered = filteredSkillSubArgSuggestions

        if filtered.isEmpty {
            Text("No matches for \"\(skillSubArgQuery)\"")
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

    private func skillSubArgRow(_ skill: SkillSlashSuggestion) -> some View {
        Button {
            onSelectSkillSubArg(skill)
        } label: {
            HStack(spacing: 12) {
                Text(skill.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let category = skill.category {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(skill.description ?? String(localized: "Skill"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                                    .font(.system(size: 15, weight: .regular))
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
            let allModels = modelGroups.flatMap(\.slashAutocompleteModels).map(\.id)
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

    private var filteredSkillSuggestions: [SkillSlashSuggestion] {
        guard !parsed.isSubArgMode else { return [] }
        return SlashSkillFormatter.matching(parsed.commandName, in: skillSuggestions)
    }

    private var filteredAgentCommandSuggestions: [AgentSlashCommandSuggestion] {
        guard !parsed.isSubArgMode else { return [] }
        let builtinNames = SlashCommandCatalog.matching(parsed.commandName)
            .map { $0.name.lowercased() }
        let skillNames = filteredSkillSuggestions.map { $0.slashName.lowercased() }
        return AgentSlashCommandSuggestion.matching(
            parsed.commandName,
            in: agentCommands,
            excluding: Set(builtinNames + skillNames)
        )
    }

    private var skillSubArgQuery: String {
        SlashSkillFormatter.skillQuery(from: parsed.argQuery)
    }

    private var filteredSkillSubArgSuggestions: [SkillSlashSuggestion] {
        SlashSkillFormatter.matching(skillSubArgQuery, in: skillSuggestions)
    }
}

struct AgentSlashCommandSuggestion: Identifiable, Equatable {
    let name: String
    let description: String
    let argHint: String?

    var id: String { name.lowercased() }

    init?(_ command: AgentCommand) {
        guard command.cliOnly != true,
              command.gatewayOnly != true,
              let name = Self.nonEmpty(command.name)
        else {
            return nil
        }

        self.name = name
        description = Self.nonEmpty(command.description) ?? String(localized: "Agent command")
        argHint = Self.nonEmpty(command.argsHint)
    }

    static func matching(
        _ query: String,
        in commands: [AgentCommand],
        excluding excludedNames: Set<String> = []
    ) -> [AgentSlashCommandSuggestion] {
        let lower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = excludedNames
        var matches: [AgentSlashCommandSuggestion] = []

        for command in commands {
            guard let suggestion = AgentSlashCommandSuggestion(command) else { continue }

            let key = suggestion.name.lowercased()
            guard !seen.contains(key) else { continue }
            guard lower.isEmpty || key.hasPrefix(lower) else { continue }

            matches.append(suggestion)
            seen.insert(key)
        }

        return matches
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
