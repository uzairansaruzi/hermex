# 0013. Bot rooms and mentions

Area: bots

## Never section rooms and keep hidden rooms unhidable

`BotInbox.sections` never sections rooms, because Desktop keeps a room's section on the machine that filed it. A hidden room lives in the revealed list whether or not it is also pinned, exactly as a hidden bot does, so it can always be unhidden.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`

## Keep the room cursor when applying an early acknowledgment

An acknowledgment can arrive ahead of unread log events. `BotRoomLog.acknowledge` inserts its bubble but keeps the previous `cursor`, so the next log read does not skip those events.

Lives in: `HermesMobile/Features/Bots/BotGroupRoom.swift`

## Do not treat file paths as bot mentions

`BotMentions.tokens` runs a handle possessively to its end and does not count it as a mention when a path continues it (`@docs/plan.md`, `@docs.md`). The composer's file references then never resolve as a bot, while trailing punctuation after a handle still does.

Lives in: `HermesMobile/Features/Bots/BotMentions.swift`

## Reserved words block only friendly bot aliases

`BotMentions.nameForms` produces Desktop's slug and collapsed name forms. Reserved words only block friendly aliases, so the primary Profile still owns @hermes and @default.

Lives in: `HermesMobile/Features/Bots/BotMentions.swift`
