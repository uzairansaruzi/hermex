# 0119. Offline cache

Area: persistence-cache

## Keep the offline cache out of the app group

Cached rows name their server's URL, so `CacheContainer` opens the SwiftData store with `CacheContainer.configuration` (`ModelConfiguration(groupContainer: .none)`) in the app's own container, which no extension reads, instead of the app group SwiftData picks by default (#1509). An existing install's store is moved out of the group with its rows by `CacheContainer.open` at launch, before anything can open the store.

Lives in: `HermesMobile/Persistence/CacheStore.swift`, `HermesMobileTests/CacheStoreTests.swift`

## Move the cache store last and delete what can't move

`CacheContainer.moveStore` moves the SQLite sidecars (`-wal`, `-shm`) first and the store itself last, replacing any files at the destination, so a move cut short runs again on the next launch. A file that can't move is deleted rather than left behind: the cache refills from the server, and the server URLs it holds must not stay in the shared container.

Lives in: `HermesMobile/Persistence/CacheStore.swift`

## Dedupe sessions a response repeats within one cache write

`CacheStore.cacheSessions` does one server-scoped fetch that serves both the upsert lookups and the stale sweep, mirroring `cacheMessages`. Rows it inserts join that lookup dictionary, so a session duplicated in the same server response updates the row already inserted instead of inserting a second row with the same unique key.

Lives in: `HermesMobile/Persistence/CacheStore.swift`

## Save a cache write before trimming

`CacheStore.saveAndTrim` saves the write first, then enforces the TTL and the message cap, so the store-side delete and count see exactly what the context holds: a row the write just refreshed is no longer expired in the store either. Maintenance never loads rows unless some must go: the expiry delete runs in the store and eviction (`evictOldestMessagesIfNeeded`) starts from a COUNT. Hermes writes in `CacheStore+Hermes.swift` end here too.

Lives in: `HermesMobile/Persistence/CacheStore.swift`

## Keep columns added after the initial schema optional

Columns added to `CachedMessage` and `CachedSession` after the initial schema stay optional so SwiftData migrates them as nullable columns on existing stores. Examples are `CachedMessage`'s display hint (such as `"steer"`) and `CachedSession.lineageRoot`, `unread` and `preview`; `lineageRoot` is a Hermes row's identity across a legacy compression chain, which `sessionID`'s tip opens, and is nil on a webui row (#1054).

Lives in: `HermesMobile/Persistence/CachedMessage.swift`, `HermesMobile/Persistence/CachedSession.swift`

## Encode cached message blobs with sorted keys

The encoder for a message's JSON columns (`CachedMessage`'s blobs) uses sorted keys so equal values encode to equal bytes. `CachedMessage.refresh` compares those bytes to decide whether a row changed.

Lives in: `HermesMobile/Persistence/CachedMessage.swift`

## Clear a server's cache before sign-out or removal tears the view down

`SettingsServerPage` purges the server's offline cache (`CacheStore.clearCache(for:in:)`) before calling `authManager.signOut()` or removing the server, while the view and its `modelContext` are still alive: changing auth state for the active server tears this stack down on its own. The purge is best-effort, because the cache is server-keyed and a leftover row can never surface as another server's content (#18, PR #286).

Lives in: `HermesMobile/Features/Settings/SettingsServerPage.swift`

## Never sweep cached Hermes rows a page left out

A Hermes server's Sessions list and transcripts (#1054) live in the webui cache's tables, so sign-out, server removal and Clear Offline Cache (`clearCache(for:)`) take them with the server's other rows. A session is keyed `<server>|hermes|<Profile>|<lineage root>` and keeps the tip it opens by as `sessionID`; a message is keyed `<server>|hermes|<Profile>|<lineage root>|row|<row id>` with the scope `hermes|<Profile>|<lineage root>` as its `sessionID`, and each Profile's own store keeps the same id in two from colliding. The list and a transcript arrive a page at a time, so no write sweeps what a page left out: a session goes only when this phone deleted or archived it, when a walk from the list's first page reached its end without it, or by the TTL; a message goes only when a newest read no longer holds it inside the row ids that read covered, from its oldest row on (a rewind or undo), or by the TTL or the cap. A Bot Chat (#1144) caches only its transcript under `hermes-bot|<connection>|<Profile>|<canonical root>`, the root `identify` finds, which a compaction that moves its stored key leaves in place; a webui list sweeps every session row of its server, so the chat finds its root again from its message rows, and an archived Bot Chat keeps its own copy under `hermes-bot-archive|<connection>|<Profile>|<root>` so it never becomes its bot's preview or goes when its bot's chat finds another root.

Lives in: `HermesMobile/Persistence/CacheStore+Hermes.swift`

## Revoke in-flight Hermes cache writers when clearing

`CacheStore` keeps a per-server Hermes cache epoch (`hermesEpochs`). Clearing the server's cache, or removing a Profile's or connection's Bot Chats (`removeHermesBotChats`, `removeHermesBotChatRoot`), moves it on through `revokeHermesWriters`; a Hermes chat takes the epoch at each attach (`hermesCacheEpoch`) and writes only while it still matches, so a write that began before the clear can't put back what went (#628).

Lives in: `HermesMobile/Persistence/CacheStore+Hermes.swift`

## Purge a deleted Profile's cached Bot Chat before the first await

`BotInbox.reload` treats a Profile the previous roster listed and the fresh one omits as deleted elsewhere and removes its cached Bot Chat (`CacheStore.removeHermesBotChats`). It does so before its first `await`, so a reopen or a newer reload cannot make `previous` forget the Profile first. `profiles` starts as the cached roster when there is one (it lives in Caches and skips very large rosters), so a deletion made while the app was closed is caught only then.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`
