# 0131. Server accounts and Move to Hermes

Area: sessions

## Key a Hermes server by BotConnection.address

`ServerAccount`'s stable per-server identity reuses the normalized base-URL string, so it matches the offline cache's `serverURLString` key (`CachedSession` / `CachedMessage`) with no separate id-to-URL mapping to keep in sync. A Hermes server's identity is its address as `BotConnection.address(_:)` normalizes it, never `AuthManager.normalizedServerURL`, whose rules differ.

Lives in: `HermesMobile/Models/ServerAccount.swift`

## Keep move records out of ServerRegistry.update

The webui servers whose chats moved to a Hermes server (Move to Hermes, #707) are recorded on the destination, so the record outlives removing the webui entry and goes with the destination; only `AuthManager.commitMove` and `updateMoveRecord` write it. How far a webui server's one-time Move to Hermes question went (#1267, nil before it is asked) lives on that server's own entry, so it is per server and goes when the server is removed; only `AuthManager.noteMovePrompt` writes it. `ServerRegistry.update` keeps both stored values, so an identity edit from an older copy can't drop them.

Lives in: `HermesMobile/Models/ServerAccount.swift`

## Give Move to Hermes's webui copy its own cookie jar

A Move's copy from the webui (#1213) uses its own client, sending that webui server's headers, not the active server's, from a cookie jar of its own seeded with its sign-in cookies. The Profile cookie each `switchProfile` sets lands only in that jar, so the app's screens never see it and none of them can change it mid-copy. The `configuration` parameter is only for tests' protocol classes, and its cookie storage is always replaced. The returned session is invalidated once the copy ends.

Lives in: `HermesMobile/Networking/APIClient+SessionExport.swift`
