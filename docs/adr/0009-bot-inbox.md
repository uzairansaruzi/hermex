# 0009. Bot inbox

Area: bots

## Keep the open bot selection in BotInbox, not the view

`BotInbox.selection`, the open bot or room, lives on the inbox model rather than the inbox view. The Hermes home's open chat then survives what rebuilds that view: a size-class change or the `[Bots | Sessions]` switch.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`

## Poll live statuses while a bot is busy

The host's `sessions.changed` can miss a turn's end, because post-turn work writes nothing. So `BotInbox` re-reads statuses on its own every `statusPollInterval` (5 s by default) while it is open, connected, and a row shows Working or Waiting; once every bot is idle it stops.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`

## Match live runtimes by both canonical root and tip, never ambiguously

`BotLiveStatus.statuses` maps `session.active_list` items onto bots by `session_key`, which is the live compression tip or, before the agent exists, the stored key; so it is matched against both the canonical root and the tip the roster read. Items carry no Profile and stored ids can repeat across Profiles, so a key that names more than one bot marks none of them. When several items land on one bot, the most urgent wins.

Lives in: `HermesMobile/Features/Bots/BotConnection.swift`

## Send Desktop's bot look back whole on writes

`BotProfile.look` holds Desktop's `ui_meta["hermes-bots"]` object as received. `BotInbox.configure` writes a pin, hide or section through `profiles.configure` by sending that whole object back with the changes applied, so Desktop-only fields survive, under the look revision the row was read at. Nothing is shown as done until the host says it applied and the roster is re-read; a conflict means Desktop wrote in between, so the fresh roster is shown and the user decides whether to retry.

Lives in: `HermesMobile/Features/Bots/BotConnection.swift`, `HermesMobile/Features/Bots/BotInbox.swift`

## Clear a bot's section with explicit nulls

`BotInbox.removeFromSection` sends `sectionId` and `sectionName` as explicit nulls rather than missing keys. Desktop merges the host's meta over its local copy, so a dropped key would keep its stale section alive.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`
