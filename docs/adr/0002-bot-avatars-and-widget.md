# 0002. Bot avatars and the Bot widget

Area: bots

## Keep the Open Bot Avatar MIT attribution

`BotAvatarGeneration.designPrompt` is adapted from Open Bot Avatar's design prompt (Dominik Scholz, MIT): flat, with a path grammar the app parses itself, and short enough for a small model to answer quickly. The silhouettes and eye positions in `BotAvatarLibrary.swift` come from Open Bot Avatar, (c) Dominik Scholz, MIT license, at commit 3a5119877844165eebafe57d3100da475f67d0a8, with curves normalized to absolute M, L, Q, C and Z. The MIT license requires this copyright notice to stay with the copied material.

Lives in: `HermesMobile/Features/Bots/BotAvatarGeneration.swift`, `HermesMobile/Features/Bots/BotAvatarLibrary.swift`

## Keep server identifiers out of the widget app group

`BotWidgetPublisher` names avatar files `<server key prefix>-<Profile digest>-<connection digest>-<look revision>`, so a new look, or a replaced connection whose host reuses the Profile name and revision, gets a new file. The connection appears only as a digest, so the app group holds no connection UUID. `BotWidgetPublisher.registryTitle` uses the server's display name, or a neutral title when the name is empty or just repeats the host, so the Bot widget's snapshot (#1643) never holds a host name; it is nil for a server no longer configured.

Lives in: `HermesMobile/Widgets/BotWidgetPublisher.swift`
