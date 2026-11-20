# 0072. Live Activity widget rendering

Area: live-activity-share-intents

## Keep dark hues for the Dynamic Island keyline

The keyline only rings the iPhone's Dynamic Island, which is always black. `AgentRunLiveActivityWidget` therefore tints `.keylineTint` from `AgentRunPalette.dark` rather than the surface-aware environment palette, which would pick light-background hues for a black ring.

Lives in: `HermesLiveActivityWidget/AgentRunLiveActivityWidget.swift`

## Bound the Live Activity timer range to MM:SS

`Text(timerInterval:)` reserves layout width for the largest value its range could ever show, then draws the shorter live value leading-aligned inside the leftover slack, which left-shifted the digits in the Dynamic Island and the Lock Screen pill (#247). The timer view bounds the range to `maxDisplayInterval` (99:59) so the box stays MM:SS-sized. An explicit `multilineTextAlignment` pins the digits to the edge each call site wants: trailing under the Dynamic Island status, centered in the pill.

Lives in: `HermesLiveActivityWidget/AgentRunLiveActivityWidget.swift`

## Key bot avatar files by connection

`BotLiveActivity.writeAvatar` renders the bot's avatar, photo or drawn face, to one PNG in the app group and returns its file name. The name is the connection's UUID plus a SHA-256 digest of the Profile id, so equal Profile names on two connections never share an image. Only one Live Activity exists at a time, so every other file in the avatar directory is deleted first.

Lives in: `HermesMobile/Features/Bots/BotLiveActivity.swift`

## Render Live Activity avatars in dark mode

The Live Activity card is always dark. `BotLiveActivity.writeAvatar` sets `.environment(\.colorScheme, .dark)` on the `ImageRenderer` content so the adaptive body color resolves for that dark card whatever the app's appearance.

Lives in: `HermesMobile/Features/Bots/BotLiveActivity.swift`
