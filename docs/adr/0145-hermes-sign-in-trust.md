# 0145. Hermes server sign-in and trust

Area: settings-onboarding-auth

## Never match saved Hermes sign-ins by install_id

`AuthManager.savedHermesSignIns(at:)` (#900) offers the sign-ins configured webui servers keep for exactly the typed address, each saved address parsed by `BotConnection.address(_:)` the way the typed one was. It never matches by `install_id`: that comes from the public `/api/status`, so any host could report another's and be offered its saved password.

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Check install_id only when both sides know it (trust on first use)

`BotConnection.requireSameInstall` is called with the live `install_id` before any password is sent, or, on a gateway's Webapp, which names it only once signed in, right after sign-in and before anything loads (#1606). It throws `.differentHost` only when both ids are known and differ; a record without one, or a host that omits it this time, connects as before. The id is public on a dashboard, so this catches an address that now reaches another host, not an impostor. `BotInbox.recordInstallID` stores the host's id on a record that has none; it re-reads the saved record rather than using `opened`, because the connection form may have saved a new password or name under the same UUID while the inbox connected, and it also updates the in-memory `connection`, because the chats, rooms, creator and editor opened from the inbox build their clients from it.

Lives in: `HermesMobile/Features/Bots/BotConnection.swift`, `HermesMobile/Features/Bots/BotInbox.swift`

## Never downgrade to HTTP after a TLS failure

`BotConnection.address` infers a scheme (HTTP via `defaultsToHTTP` for private and local hosts) only when the typed address omits one. It is never a retry after HTTPS fails, which would silently downgrade the connection to plaintext.

Lives in: `HermesMobile/Features/Bots/BotConnection.swift`

## Persist rotated OAuth refresh tokens before use

A connection signed in through the host's browser sign-in (#708) keeps its account and refresh token on the `BotConnection` record. The host rotates `refreshToken` on every refresh, so the live `HermesConnection` holds the current one and saves it with `BotConnectionStore.saveRotatedRefreshToken` before using the access token it came with; an in-memory copy of the record can hold a token the host has since replaced. `saveRotatedRefreshToken` writes only while the server's record is still connection `id` holding `sent`, the token that connection last saw saved, so a record removed or signed in again meanwhile keeps what it has. It never retires the live connection, which made the change.

Lives in: `HermesMobile/Features/Bots/BotConnection.swift`

## Sign in a candidate connection on its own cookie jar

`BotConnectionSetup` builds the candidate's wire with `BotClient(connection:)` on its own cookie jar. The connection isn't saved yet, so it must never sign in on the server's shared one.

Lives in: `HermesMobile/Features/Bots/BotConnectionView.swift`

## Never resend a rejected password automatically

After a 401, `BotInbox.open` returns early while `needsSignIn` is set instead of resending the saved password, because each resend spends one of the host's ten password logins a minute per client IP, which Desktop and the browser may share behind the same tunnel (#884). In a chat, `HermesChatTurnCoordinator` handles `.rejected(401)` (#884, #942) by setting `needsSignIn`, after which nothing on that chat attaches again (`startAttach` returns early). The chat offers Update sign-in, which closes it, and the next chat signs in with what the form saved.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`, `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`
