# 0117. Bot room history cache

Area: persistence-cache

## Never save a room cursor across a replay gap

`BotHistoryCache.appendRoom` merges a replay page into the previous snapshot only when it overlaps the saved range (`since` at or before the saved cursor and the page's cursor at or after `earlierBoundary`). Otherwise it retains only the newly read window, so a gap in history can never become a saved cursor.

Lives in: `HermesMobile/Features/Bots/BotHistoryCache.swift`

## Persist cursor-only room changes lazily, with a periodic save

Invisible events move only the cursor, so `BotHistoryCache.appendRoom` keeps that cursor in memory and lets the next real write persist it. After a kill, reopening re-reads from the older saved cursor and the overlap merge absorbs the repeated pages. A periodic save every `cursorOnlySaveInterval` (10 minutes) keeps a long-running room's saved `savedAt` fresh so it cannot expire past `lifetime` (30 days) on relaunch.

Lives in: `HermesMobile/Features/Bots/BotHistoryCache.swift`

## Cache a room's replay window in one write

`BotRoomReader.readPages` commits the complete contiguous window of pages to `BotHistoryCache` together. Saving earlier pages one at a time would temporarily leave a gap before the already-cached window. Storage is best-effort; its failures never stop live reading.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Guard recent room transcripts with a lock, not an actor

`BotRecentTranscripts` holds each recent room's rendered window, separate from the lossy on-disk search index, so reopening a room draws its last window before the first poll. It is a lock-protected `@unchecked Sendable` class because screens read it synchronously before their first frame while the `BotHistoryCache` actor invalidates entries. Only value-type logs cross it: no clients, callbacks, approval state or credentials.

Lives in: `HermesMobile/Features/Bots/BotHistoryCache.swift`

## Claim recent-transcript writes at recovery start, not view construction

`BotRecentTranscripts.begin` hands out a new owner token when a room screen starts recovery, not during SwiftUI construction. `save` writes only for the current owner, so a later owner or a removal makes every older writer inert.

Lives in: `HermesMobile/Features/Bots/BotHistoryCache.swift`
