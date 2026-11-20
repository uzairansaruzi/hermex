# 0015. Bots inbox

Area: bots

## Resolve deep-linked bots against the live roster

`BotsInboxView` holds a deep link's `pendingDestination` and resolves it there, because that is where the live roster is. `openPendingDestination` first resets the selection to the inbox: a pushed screen closes the inbox socket, and returning lets the inbox's appearance task reconnect and resolve the link, as when the Sessions list opens a Bot Chat it found (#1053). A connecting or retrying socket keeps the link pending, so a dropped socket or a manual Reconnect still routes it. The link is cleared once the inbox has settled (`hasSettled`), whether or not it matched; a replaced connection or a Profile the server no longer has leaves the user on the inbox rather than guessing (#554).

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`

## Use Menu with a primary action for pinned bot tiles

The pinned bots' `LazyVGrid` is one List row, and a row merges every `.contextMenu` inside it into one, so holding any tile lifted the whole grid with the first bot's menu. Each pinned tile is a `Menu` with a primary action instead: it is its own control, so a tap opens the chat and a hold shows that chat's menu.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`

## Reserve status space on pinned bot tiles

`BotHeroTile` draws the longer status (`.waiting`), hidden, to hold the status line's height at the current text size whether a status shows or not. Statuses arrive after the tiles, and a tile changing height moved the whole list under the pinned bots. The line allows two lines so a long translation at a large text size still reads whole.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`

## Render Desktop section names verbatim

`BotsInboxView` renders Hermes Desktop section names with `Text(verbatim:)`, because a Desktop name is the user's own text, never a String Catalog key.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`

## Disable full swipe on bot inbox rows

The row swipe actions offer the same writes as the long-press menu, with `allowsFullSwipe: false` on both edges: Delete confirms and Pin is a server write, so nothing should fire from a flick. On the trailing edge Hide sits at the edge with Delete behind it, so a short swipe reaches the reversible action first.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`

## Identify bot chats by a composite id

The selected bot's `ChatView` is keyed with `.id([profile.id, connection.id.uuidString, conversation])`, an array rather than a concatenated string. A Profile name and a conversation root are both arbitrary server strings, so joining them could let two destinations share one identity and keep the wrong conversation on screen.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`
