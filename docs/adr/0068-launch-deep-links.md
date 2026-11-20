# 0068. Launch deep links

Area: live-activity-share-intents

## Route launch deep links from both the initial task and onChange

A cold launch delivers a link before the receiving view appears, so `.onChange` never fires for it; a warm launch delivers it afterwards. `ContentView` calls `drainPendingIntentDeepLink()` in its initial `.task` as well as in `.onChange(of: intentRouter.pendingDeepLink)`, because an App Intent such as the Action button's New Chat may queue a link before the view appears (#337). `SessionListView` likewise calls `showBotsForPendingDestination()` from both `.task` and `.onChange(of: pendingBotDestination)`.

Lives in: `HermesMobile/ContentView.swift`, `HermesMobile/Features/SessionList/SessionListView.swift`

## Give each new-chat request a fresh id

`ContentView.handleOpenURL` builds a new request with a fresh `id` for every New Chat link, so a repeat invocation re-triggers navigation even if the previous request's value still lingers downstream. The voice variant carries `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).

Lives in: `HermesMobile/ContentView.swift`

## Defer releasing an unopenable Shortcut text a turn

The unopenable-Shortcut alert's `isPresented` setter treats a dismissal without a button (Escape, VoiceOver's escape) as Not Now and releases the share. A button's action may run after the setter, so the release waits a main-actor turn and is skipped when the pending reservation has already settled.

Lives in: `HermesMobile/ContentView.swift`

## Never open a server-scoped session link on another server

`HermesDeepLink.sessionID(from:)` returns the session a legacy `session?id=` (or `session/<id>`) link names, opened on a webui server. A link carrying a `server` item returns nil there: it opens only on the server it names (#1176), or not at all, never on whichever webui server is reachable.

Lives in: `HermesMobile/LiveActivities/HermesDeepLink.swift`

## Give an archived Bot Chat's Live Activity the hermes: session identity

A Bot Chat row opened from Archived, including a legacy "Bot Chat (continued)" tip, resumes its stored key; `HermesSessionChat.botChatRoot` keeps Bot Chat's rules, caches under the root, and reads its bot's Bot Chat copy while it has none (#1144). The chat may be a deliberate archive that upstream's title lookup leaves out, or one the bot has since replaced. Its Live Activity therefore keeps the `hermes:` session identity, whose tap is the session link to its key (#1165, #1179), with no Bot route, so a tap never reaches the canonical title lookup, opens the replacement, or unarchives the original.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`, `HermesMobileTests/HermesChatLiveActivityTests.swift`
