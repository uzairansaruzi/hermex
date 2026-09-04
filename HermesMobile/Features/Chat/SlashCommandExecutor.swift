import Foundation
import SwiftData

struct ParsedSlashCommand: Equatable {
    let command: SlashCommand?
    let name: String
    let args: String
}

enum SlashCommandExecutionResult: Equatable {
    case executed(message: String?)
    case openedSession(SessionSummary)
    case sendAsMessage
    case unsupported(friendlyMessage: String)
    case needsSubArg
}

enum SlashCommandExecutor {
    static func parse(_ text: String) -> ParsedSlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let withoutSlash = String(trimmed.dropFirst())
        guard !withoutSlash.isEmpty else {
            return ParsedSlashCommand(command: nil, name: "", args: "")
        }

        let parts = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let name = parts.first.map(String.init) ?? ""
        let args = parts.dropFirst().first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""

        return ParsedSlashCommand(
            command: SlashCommandCatalog.command(named: name),
            name: name,
            args: args
        )
    }

    /// `modelContext` reaches the handful of commands that rewrite the offline
    /// cache (`/clear`); callers with no SwiftData context can omit it.
    @MainActor
    static func execute(
        text: String,
        viewModel: ChatViewModel,
        modelContext: ModelContext? = nil
    ) async -> SlashCommandExecutionResult {
        guard let parsed = parse(text) else { return .sendAsMessage }
        guard !parsed.name.isEmpty else { return .needsSubArg }

        guard let command = parsed.command else {
            if isKnownUnsupportedCommand(parsed.name) {
                return .unsupported(friendlyMessage: unsupportedMessage(for: parsed.name))
            }
            if parsed.name.lowercased() == "skill" {
                return .unsupported(friendlyMessage: String(localized: "Use `/skills [query]` to search skills."))
            }
            if let result = await viewModel.executeSkillShortcutCommand(name: parsed.name, args: parsed.args) {
                return result
            }
            // Match WebUI: let the agent/runtime handle unknown, non-blocked slash text.
            return .sendAsMessage
        }

        switch command.handler {
        case .clientSide, .serverSide:
            return await viewModel.executeSlashCommand(
                command,
                args: parsed.args,
                modelContext: modelContext
            )
        case .unsupported:
            return .unsupported(friendlyMessage: unsupportedMessage(for: command.name))
        }
    }

    static func unsupportedMessage(for commandName: String) -> String {
        switch commandName.lowercased() {
        case "terminal":
            return String(localized: "Terminal is not available in the mobile app.")
        case "theme":
            return String(localized: "Theme switching is not available from mobile slash commands.")
        case "voice":
            return String(localized: "Voice commands are not available in the mobile app.")
        case "yolo":
            return String(localized: "YOLO mode is not available in the mobile app.")
        default:
            return String(localized: "This command is not available in the mobile app.")
        }
    }

    static func isKnownUnsupportedCommand(_ commandName: String) -> Bool {
        switch commandName.lowercased() {
        case "terminal", "theme", "voice", "yolo":
            return true
        default:
            return false
        }
    }
}
