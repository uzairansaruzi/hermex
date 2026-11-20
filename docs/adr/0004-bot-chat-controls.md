# 0004. Bot chat controls

Area: bots

## Read the active model only from model.options

In `BotChatControls.snapshot`, `session.info`'s `model` can be the queued choice, so it never sets the active tick; only `model.options` reads the live agent's model and provider. A reported model that differs from `pendingModel` clears the pending badge, because Desktop may replace or cancel the queued choice, or the next turn may resolve an alias to a canonical model.

Lives in: `HermesMobile/Features/Bots/BotChatControls.swift`

## Invalidate in-flight catalog reads when a setting write starts

`BotChatControls.apply` invalidates reads before it dispatches a model or setting write. A read started before the write must not overwrite the write's authoritative response.

Lives in: `HermesMobile/Features/Bots/BotChatControls.swift`

## Queue bypasses the host's busy input behavior

`BotPromptMode` is bot-only: Send is the only choice while the bot is idle, and the other three (Steer, Queue, and Redirect, titled Interrupt) are offered when a send lands on a working bot. Queue explicitly bypasses the host's configurable busy input behavior, which could otherwise interrupt work started by Desktop.

Lives in: `HermesMobile/Features/Bots/BotPromptMode.swift`
