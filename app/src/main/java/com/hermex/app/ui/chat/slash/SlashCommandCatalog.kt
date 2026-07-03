package com.hermex.app.ui.chat.slash

import java.util.Locale

/** Android port of the iOS mobile-safe slash-command catalog. */
data class SlashCommand(
    val name: String,
    val description: String,
    val argHint: String? = null,
    val noEcho: Boolean = false,
    val handler: SlashCommandHandler = SlashCommandHandler.Unsupported,
    val subArgs: SlashCommandSubArgs = SlashCommandSubArgs.None
)

sealed interface SlashCommandHandler {
    data object Unsupported : SlashCommandHandler
    data class ClientSide(val action: ClientSideAction) : SlashCommandHandler
    data class ServerSide(val action: ServerSideAction) : SlashCommandHandler
}

enum class ClientSideAction { Clear, Stop, New, Help }

enum class ServerSideAction {
    Model,
    Workspace,
    Reasoning,
    Title,
    Personality,
    Skills,
    Compress,
    Retry,
    Undo,
    Branch,
    Queue,
    Steer,
    Interrupt,
    Status,
    Btw,
    Background,
    Goal
}

enum class SlashCommandSubArgs { None, Models, Personalities, ReasoningLevels, Workspaces, Skills, GoalActions }

data class ParsedSlashQuery(val query: String) {
    private val normalized = query.trimStart()
    val isSlashQuery: Boolean = normalized.startsWith("/")
    private val withoutSlash = if (isSlashQuery) normalized.drop(1) else normalized
    private val firstSpaceIndex = withoutSlash.indexOfFirst { it.isWhitespace() }
    val commandName: String = when {
        !isSlashQuery -> ""
        firstSpaceIndex < 0 -> withoutSlash.trim().lowercase(Locale.ROOT)
        else -> withoutSlash.substring(0, firstSpaceIndex).trim().lowercase(Locale.ROOT)
    }
    val argQuery: String = when {
        !isSlashQuery || firstSpaceIndex < 0 -> ""
        else -> withoutSlash.substring(firstSpaceIndex + 1).trimStart()
    }
    val isSubArgMode: Boolean = isSlashQuery && firstSpaceIndex >= 0
    val command: SlashCommand? = SlashCommandCatalog.command(commandName)
}

object SlashCommandCatalog {
    val reasoningLevels = listOf("show", "hide", "none", "minimal", "low", "medium", "high", "xhigh")
    val goalActions = listOf("status", "pause", "resume", "clear")

    val allCommands: List<SlashCommand> = listOf(
        SlashCommand("help", "Show available slash commands", handler = SlashCommandHandler.ClientSide(ClientSideAction.Help)),
        SlashCommand("clear", "Clear the current conversation", noEcho = true, handler = SlashCommandHandler.ClientSide(ClientSideAction.Clear)),
        SlashCommand("model", "Switch the active model", "model_name", true, SlashCommandHandler.ServerSide(ServerSideAction.Model), SlashCommandSubArgs.Models),
        SlashCommand("workspace", "Switch the active workspace", "path", true, SlashCommandHandler.ServerSide(ServerSideAction.Workspace), SlashCommandSubArgs.Workspaces),
        SlashCommand("reasoning", "Set reasoning effort level", "level", true, SlashCommandHandler.ServerSide(ServerSideAction.Reasoning), SlashCommandSubArgs.ReasoningLevels),
        SlashCommand("new", "Start a new session", noEcho = true, handler = SlashCommandHandler.ClientSide(ClientSideAction.New)),
        SlashCommand("stop", "Stop the current response", noEcho = true, handler = SlashCommandHandler.ClientSide(ClientSideAction.Stop)),
        SlashCommand("title", "Rename the current session", "name", false, SlashCommandHandler.ServerSide(ServerSideAction.Title)),
        SlashCommand("personality", "Set the session personality", "name", false, SlashCommandHandler.ServerSide(ServerSideAction.Personality), SlashCommandSubArgs.Personalities),
        SlashCommand("skills", "Search available skills", "query", false, SlashCommandHandler.ServerSide(ServerSideAction.Skills), SlashCommandSubArgs.Skills),
        SlashCommand("compress", "Compress session context", "focus topic", true, SlashCommandHandler.ServerSide(ServerSideAction.Compress)),
        SlashCommand("compact", "Alias for /compress", "focus topic", true, SlashCommandHandler.ServerSide(ServerSideAction.Compress)),
        SlashCommand("retry", "Retry the last turn", noEcho = true, handler = SlashCommandHandler.ServerSide(ServerSideAction.Retry)),
        SlashCommand("undo", "Undo the last exchange", noEcho = true, handler = SlashCommandHandler.ServerSide(ServerSideAction.Undo)),
        SlashCommand("branch", "Fork the conversation", "name", true, SlashCommandHandler.ServerSide(ServerSideAction.Branch)),
        SlashCommand("fork", "Alias for /branch", "name", true, SlashCommandHandler.ServerSide(ServerSideAction.Branch)),
        SlashCommand("queue", "Queue a message for the next turn", "message", true, SlashCommandHandler.ServerSide(ServerSideAction.Queue)),
        SlashCommand("steer", "Steer the active response", "message", true, SlashCommandHandler.ServerSide(ServerSideAction.Steer)),
        SlashCommand("interrupt", "Stop the response and send a new message", "message", true, SlashCommandHandler.ServerSide(ServerSideAction.Interrupt)),
        SlashCommand("status", "Show session status", handler = SlashCommandHandler.ServerSide(ServerSideAction.Status)),
        SlashCommand("goal", "Set or inspect a persistent goal", "[status|pause|resume|clear|text]", true, SlashCommandHandler.ServerSide(ServerSideAction.Goal), SlashCommandSubArgs.GoalActions),
        SlashCommand("btw", "Ask a side question", "question", true, SlashCommandHandler.ServerSide(ServerSideAction.Btw)),
        SlashCommand("background", "Run a parallel task", "prompt", true, SlashCommandHandler.ServerSide(ServerSideAction.Background)),
        SlashCommand("bg", "Alias for /background", "prompt", true, SlashCommandHandler.ServerSide(ServerSideAction.Background))
    )

    fun matching(query: String): List<SlashCommand> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return allCommands
        val lower = trimmed.lowercase(Locale.ROOT)
        return allCommands.filter {
            it.name.lowercase(Locale.ROOT).startsWith(lower) ||
                it.description.lowercase(Locale.ROOT).contains(lower)
        }
    }

    fun command(name: String): SlashCommand? {
        val lower = name.lowercase(Locale.ROOT)
        return allCommands.firstOrNull { it.name.lowercase(Locale.ROOT) == lower }
    }
}
