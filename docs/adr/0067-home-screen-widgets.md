# 0067. Home Screen widgets

Area: live-activity-share-intents

## Keep widget snapshots free of server URLs and credentials

The app writes each widget's snapshot (`BotWidgetPublisher` for `BotWidgetSnapshot`, #1643; `ProviderLimitsPublisher` for `ProviderLimitsSnapshot`, #1409), and the widget and its pickers only read it, so no widget makes a network or Keychain call. A snapshot holds no server URL, host, credential or session: a server is a SHA-256 digest of its configured URL (`BotHistoryCache.Scope.key`). The Bot snapshot also holds no connection UUID and names a bot by its Profile name; the Limits snapshot keeps the Profile and the Bot connection's UUID to name the scope a tap opens (`HermesUsageDestination`). Both types are shared by the app and the widget.

Lives in: `HermesMobile/Widgets/BotWidgetSnapshot.swift`, `HermesMobile/Widgets/ProviderLimitsSnapshot.swift`

## Re-ask hourly while a widget bot looks unavailable

`BotWidgetTimeline` returns a single entry: the snapshot only changes when the app writes it, and that write reloads the widget. An entry with an unavailable bot asks again after an hour, because before the first unlock after a restart the snapshot can't be read and every bot looks gone.

Lives in: `HermesLiveActivityWidget/BotWidget.swift`

## Add a timeline entry at every limit window expiry

The Limits widget (#1409) draws from `ProviderLimitsSnapshot`, written when Usage loads on a Hermes server; opening Usage is the only refresh. Each window shows its percentage until the earlier of its reset and an hour after its measurement, then asks to open Hermex. `ProviderLimitsTimeline.getTimeline` emits an entry now and one at each later expiry instant (`deadlines(after:)`) rather than trusting WidgetKit to reload on time.

Lives in: `HermesLiveActivityWidget/ProviderLimitsWidget.swift`

## Gate Limits widget writes on the newest Usage ticket

`ProviderLimitsPublisher` gives each Usage load a `Ticket` before it awaits the host, and only the newest ticket writes, so a closed Usage screen's late load can't replace the Profile opened after it. Every invalidation (a server switch, sign-out, the server's removal, its connection replaced) ends the newest ticket before clearing the file, so a load that started earlier can never write its old result back. The publisher is main-actor, so publications and invalidations are serialized, and nothing in it polls or reads the host.

Lives in: `HermesMobile/Widgets/ProviderLimitsPublisher.swift`

## Open widget Usage links only on the active server's same connection

A Limits widget tap opens the Usage screen for the Profile its snapshot was loaded in, on the server and Bot connection it was loaded through; the server is the snapshot's digest, so the link carries no URL. `HermesUsageDestination.opens(state:servers:)` is true only on the signed-in active Hermes server it names, through the same saved connection. Anything else opens the app as it is and never switches servers; the Sessions list then checks the host still has the Profile.

Lives in: `HermesMobile/Widgets/ProviderLimitsPublisher.swift`, `HermesMobile/Widgets/ProviderLimitsSnapshot.swift`

## Render widget avatars after inbox photos load

`BotInbox.refreshAvatars` calls `widgets.renderAvatars` only after the avatar photos are fetched, so a configured Bot widget gets its bot's photo rather than its drawn face.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`
