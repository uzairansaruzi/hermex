# 0006. Bot connection lifecycle

Area: bots

## Remove a server's Bot roster and widget rows only after its connection retires

A Bots inbox still on screen can save a roster it reads during the awaits of a sign-out or server removal and write the rows back (#1403). So `AuthManager.signOut` calls `BotRosterCache.shared.remove(server:)` only once `removeBotConnection` has retired the shared Hermes connection, and its webui branch and `AuthManager.removeServer` do the same after the Bot record and its connection are gone. `removeServer` and the webui sign-out also call `BotWidgetPublisher.shared.remove(server:)` at that point, for the same reason. A Hermes sign-out deliberately keeps the widget rows, so a Bot widget still opens its bot after the next sign-in (#1643).

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Probe the shared Bot socket after a network path change

A network handover can leave the shared Bot socket open but dead. When `NetworkPathMonitor.shared.changeCount` changes, `ContentView` calls `HermesConnections.shared.networkPathDidChange()` (only outside the background and when the path is satisfied), and that one probe checks the socket for every Bot screen (#1372). The background has already closed the socket, so there is nothing to probe there.

Lives in: `HermesMobile/ContentView.swift`

## Keep bot connections through the inactive scene phase

Control Center and banners put the scene in `.inactive`, and Bot screens keep their connection through it (#902); only `.background` suspends. `BotProfileEditorView` reloads on return only when the editor holds no connection, and never over unsaved edits.

Lives in: `HermesMobile/Features/Bots/BotProfileEditorView.swift`

## Re-read the saved connection after painting the cached roster

`BotInbox.open` paints the roster this connection last read while it connects (#1403); that roster claims nothing live, allows no server edit, and the first read replaces it. The connection form may save or remove the record during the cache load without closing the inbox, so the record is re-read before painting or connecting. A refresh token that another client of a browser sign-in rotates meanwhile (`saveRotatedRefreshToken`) is still this connection, opened on the new token.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`

## Report a failed open only while the client still owns the inbox

In `BotInbox.open`'s catch, `drop(client, error:)` runs only while `wire === client`. The socket's own disconnect callback may already have dropped this client and scheduled the quiet retry, and a second report would paint the error message over it.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`

## Load the connection form's saved record only once

`BotConnectionView` loads its saved record once, guarded by its `loaded` flag. Coming back from the pushed headers editor reruns `.task`, which must not replace the edits in progress; the status is checked again only if leaving cancelled that check.

Lives in: `HermesMobile/Features/Bots/BotConnectionView.swift`

## Keep the setup prompt generic and credential-free

The copyable setup `prompt` in `BotConnectionView` holds generic instructions only: no credentials or configured host is copied into it. The agent discovers its installed version instead of following pinned CLI recipes.

Lives in: `HermesMobile/Features/Bots/BotConnectionView.swift`
