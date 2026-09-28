import Foundation

enum SlashCommandCatalog {
    static let allCommands: [SlashCommand] = [
        SlashCommand(
            name: "help",
            description: String(localized: "Show available slash commands"),
            noEcho: false,
            handler: .clientSide(.help)
        ),
        SlashCommand(
            name: "clear",
            description: String(localized: "Clear this conversation on the server"),
            noEcho: true,
            handler: .clientSide(.clear)
        ),
        SlashCommand(
            name: "model",
            description: String(localized: "Switch the active model"),
            argHint: String(localized: "model_name"),
            noEcho: true,
            handler: .serverSide(.model),
            subArgs: .models
        ),
        SlashCommand(
            name: "workspace",
            description: String(localized: "Switch the active workspace"),
            argHint: String(localized: "path"),
            noEcho: true,
            handler: .serverSide(.workspace),
            subArgs: .workspaces
        ),
        SlashCommand(
            name: "reasoning",
            description: String(localized: "Set reasoning effort level"),
            argHint: String(localized: "level"),
            noEcho: true,
            handler: .serverSide(.reasoning),
            subArgs: .reasoningLevels
        ),
        SlashCommand(
            name: "new",
            description: String(localized: "Start a new session"),
            noEcho: true,
            handler: .clientSide(.new)
        ),
        SlashCommand(
            name: "stop",
            description: String(localized: "Stop the current response"),
            noEcho: true,
            handler: .clientSide(.stop)
        ),
        SlashCommand(
            name: "title",
            description: String(localized: "Rename the current session"),
            argHint: String(localized: "name"),
            noEcho: false,
            handler: .serverSide(.title)
        ),
        SlashCommand(
            name: "personality",
            description: String(localized: "Set the session personality"),
            argHint: String(localized: "name"),
            noEcho: false,
            handler: .serverSide(.personality),
            subArgs: .personalities
        ),
        SlashCommand(
            name: "skills",
            description: String(localized: "Search available skills"),
            argHint: String(localized: "query"),
            noEcho: false,
            handler: .serverSide(.skills),
            subArgs: .skills
        ),
        SlashCommand(
            name: "compress",
            description: String(localized: "Compress session context"),
            argHint: String(localized: "focus topic"),
            noEcho: true,
            handler: .serverSide(.compress)
        ),
        SlashCommand(
            name: "compact",
            description: String(localized: "Alias for \("/compress")"),
            argHint: String(localized: "focus topic"),
            noEcho: true,
            handler: .serverSide(.compress)
        ),
        SlashCommand(
            name: "retry",
            description: String(localized: "Retry the last turn"),
            noEcho: true,
            handler: .serverSide(.retry)
        ),
        SlashCommand(
            name: "undo",
            description: String(localized: "Undo the last exchange"),
            noEcho: true,
            handler: .serverSide(.undo)
        ),
        SlashCommand(
            name: "branch",
            description: String(localized: "Fork the conversation"),
            argHint: String(localized: "name"),
            noEcho: true,
            handler: .serverSide(.branch)
        ),
        SlashCommand(
            name: "fork",
            description: String(localized: "Alias for \("/branch")"),
            argHint: String(localized: "name"),
            noEcho: true,
            handler: .serverSide(.branch)
        ),
        SlashCommand(
            name: "queue",
            description: String(localized: "Queue a message for the next turn"),
            argHint: String(localized: "message"),
            noEcho: true,
            handler: .serverSide(.queue)
        ),
        SlashCommand(
            name: "steer",
            description: String(localized: "Steer the active response"),
            argHint: String(localized: "message"),
            noEcho: true,
            handler: .serverSide(.steer)
        ),
        SlashCommand(
            name: "interrupt",
            description: String(localized: "Stop the response and send a new message"),
            argHint: String(localized: "message"),
            noEcho: true,
            handler: .serverSide(.interrupt)
        ),
        SlashCommand(
            name: "status",
            description: String(localized: "Show session status"),
            noEcho: false,
            handler: .serverSide(.status)
        ),
        SlashCommand(
            name: "goal",
            description: String(localized: "Set or inspect a persistent goal"),
            argHint: "[status|pause|resume|clear|text]",
            noEcho: true,
            handler: .serverSide(.goal),
            subArgs: .goalActions
        ),
        SlashCommand(
            name: "btw",
            description: String(localized: "Ask a side question"),
            argHint: String(localized: "question"),
            noEcho: true,
            handler: .serverSide(.btw)
        ),
        SlashCommand(
            name: "background",
            description: String(localized: "Run a parallel task"),
            argHint: String(localized: "prompt"),
            noEcho: true,
            handler: .serverSide(.background)
        ),
        SlashCommand(
            name: "bg",
            description: String(localized: "Alias for \("/background")"),
            argHint: String(localized: "prompt"),
            noEcho: true,
            handler: .serverSide(.background)
        )
    ]

    /// The commands worth showing for `query`, best first. An empty query keeps
    /// the curated order above.
    static func matching(_ query: String, limit: Int = SlashCommandRanker.resultLimit) -> [SlashCommand] {
        SlashCommandRanker.rank(allCommands, matching: query, limit: limit) { command in
            SlashRankableFields(name: command.name, description: command.description)
        }
    }

    /// Every built-in command name, lowercased. Used to keep an agent command
    /// that shadows a built-in out of the popover.
    static let builtinNames: Set<String> = Set(allCommands.map { $0.name.lowercased() })

    static func command(named name: String) -> SlashCommand? {
        allCommands.first { $0.name.lowercased() == name.lowercased() }
    }

    static let reasoningLevels = ["show", "hide", "none", "minimal", "low", "medium", "high", "xhigh"]
    static let goalActions = ["status", "pause", "resume", "clear"]
}
