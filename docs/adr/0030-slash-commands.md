# 0030. Slash commands

Area: chat-composer

## Identify host command rows by their canon key

A Hermes host's `commands.catalog` (#1036) lists its registry, quick and plugin commands with their aliases, and its skills. The host lists aliases only in `canon` and skills only in `skills`, so a command row is a `pairs` row whose key `canon` knows.

Lives in: `HermesMobile/Features/Chat/HermesSlashCommands.swift`

## Show the typed line for a sent skill

A skill's `send` message is the expanded skill and is never shown. The bubble shows the reply's `display`, or for a `skill` reply the typed line, because the host projects the typed line over the expanded skill once stored.

Lives in: `HermesMobile/Features/Chat/HermesSlashCommands.swift`

## Refuse /rollback --all from the phone

`--all` would overwrite the user's own edits too, so the parser treats it as a usage error and returns nil. A phone keeps the host's default rollback, which keeps those edits.

Lives in: `HermesMobile/Features/Chat/HermesSlashCommands.swift`

## Drop stale background slash ranking results

`SlashCommandAutocompleteView` ranks results in a background pass that does not inherit its `.task(id: rankingInput)` cancellation, so a pass started for an older query can still finish last. The task checks `Task.isCancelled` after the pass and drops the result rather than let it overwrite newer rows.

Lives in: `HermesMobile/Features/Chat/SlashCommandAutocompleteView.swift`

## Send unknown slash commands as messages, matching webui

`SlashCommandExecutor` matches WebUI: unknown, non-blocked slash text goes to the agent as a message and the agent or runtime handles it.

Lives in: `HermesMobile/Features/Chat/SlashCommandExecutor.swift`

## Run slash-list loads outside the cancellable caller

The composer asks for the skill and personality lists from `.task` modifiers that SwiftUI cancels on an unrelated view update; the chip warm-up for a restored draft is keyed on the draft itself, so hydrating one cancels it. The requests used to run inside the caller, so that cancellation threw them away and left a draft's `/skill` references drawn as plain text and the personality picker permanently empty (#387). `ChatViewModel.loadSkillSlashSuggestions` and `loadPersonalitySuggestions` run the fetch in a shared unstructured `Task` that a cancelled caller cannot take down.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`
