# 0005. Bot Chat prompts and commands

Area: bots

## Read canonical prompt receipts with the turn state

`BotPromptMode.outcome` reads what the host's reply says about a prompt. A `canonical` host answers a send with an admission receipt (#1602) whose status is `queued` even on an idle session, where the prompt starts at once, so `turnRunning` tells a follow-up from a start. A reply naming no `admission_id`, or any other receipt, claims nothing ran.

Lives in: `HermesMobile/Features/Bots/BotPromptMode.swift`

## Offer only skills in the bot slash panel

`BotSlashCatalog` surfaces only skills from a Bot connection's `commands.catalog`. The gateway never interprets a leading `/` in `prompt.submit`; slash work lives in `slash.exec` and `command.dispatch`, and Bot Mode exposes no general slash runner, so a command row would insert text nothing runs.

Lives in: `HermesMobile/Features/Bots/BotSlashCommands.swift`

## Drop skills shadowed by registry or quick commands

The host answers `commands.catalog` in two halves: the `skills` keys say which entries are skills, and the `pairs` rows carry every entry's description. `BotSlashCatalog.skills` drops a key that also appears in `canon` or `commands`, because those are registry, quick or plugin commands that `command.dispatch` resolves ahead of skills, and a `quick_commands` entry of type `exec` runs a shell command on the host. Names are never invented from `pairs` alone.

Lives in: `HermesMobile/Features/Bots/BotSlashCommands.swift`

## Find the Bot Chat by exact title on every attach

`ConversationTarget.canonicalChat` looks up the Profile's one Bot Chat by its exact title on every attach (`HermesConversation.identify`) rather than caching a session key. Since hermes-agent 0.22.3 the host moves aside a Bot Chat it can't own, retitled and unhidden, and makes a new one under the title, so a root that changed since the last attach is the host's new Bot Chat: the attach follows it and the owner says so (#1339). Bot Chats are created only by `BotCreator` or the host. A session resumes its own key, which the host follows to a compression tip, and a new session is created once, then is a session.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`
