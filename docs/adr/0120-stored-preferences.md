# 0120. Stored preferences

Area: persistence-cache

## Key the CLI-sessions toggle per server

The CLI-sessions toggle mirrors the active server's own `show_cli_sessions` setting, so since #19 it is stored per server under `SessionRowDisplaySettings.showCliSessionsKey(for:)`, keyed by the server's absolute URL like the offline cache; a value adopted from server A must not leak to server B. `SessionListView` configures its `showsCliSessions` `@AppStorage` key in `init`, where the server URL is known. The legacy global `sessionRow.showCliSessions` key survives only as the migration seed for servers with no per-server value yet.

Lives in: `HermesMobile/Features/SessionList/SessionListView.swift`, `HermesMobile/Features/SessionList/SessionRowView.swift`

## Only append Text Size stops

`AppTextSize.stops` is stored by position under `appearance.textSizeStop`, so stops may only be appended: inserting or reordering would change every user's saved size. The first stop (nil) follows the iPhone.

Lives in: `HermesMobile/Config/AppTheme.swift`

## Keep the legacy timestamp preference key

`ChatTranscriptSettings.showsAssistantTurnTimestampsKey` backs Settings → Chat "Message Timestamps", the time under each user message and each finished reply. Its key `chatTranscript.showsAssistantTurnTimestamps` predates the setting's move under the message and stays, so a stored choice keeps working; renaming it would drop every stored choice.

Lives in: `HermesMobile/Config/AppTheme.swift`

## Keep the new-session Profile pick client-side

`HermesProfilePreference` remembers, per server, the Profile a new Hermes session starts in (#1015). It is client state and is never written to the host, whose `POST /api/profiles/active` would move the CLI's and gateways' default too. Sign-out and server removal clear it in `AuthManager`.

Lives in: `HermesMobile/Features/Chat/HermesChatSettings.swift`, `HermesMobile/Auth/AuthManager.swift`
