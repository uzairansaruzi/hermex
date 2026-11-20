# 0164. Lists, forms, and dialogs

Area: ui-theming

## Use borderless buttons inside form rows

In a SwiftUI List or Form row, a default-style button makes the whole row its tap target. `PluginSecretField`'s Save Key and Remove Key buttons and `PluginSetupSection`'s Save Key button use `.buttonStyle(.borderless)`, so each button takes only its own taps and a tap anywhere else in the row saves nothing.

Lives in: `HermesMobile/Features/Settings/PluginDetailView.swift`, `HermesMobile/Features/Settings/PluginInstallSheet.swift`

## Attach alerts to the button, not the Section

A SwiftUI Section's own modifiers run once per row (#1255). The active webui server's page carries its sections' loads and dialogs on the page's list (`webuiServerPresentations`), and `OfflineDataSection` carries its Clear Offline Cache alert on its button. Clear Offline Cache deletes this server's offline data (`clear`), never another server's, its drafts, or its push pairing.

Lives in: `HermesMobile/Features/Settings/SettingsRows.swift`, `HermesMobile/Features/Settings/WebuiServerSettings.swift`

## Capture the pending removal synchronously before the alert clears it

`PluginsModel.confirmPendingRemoval` runs synchronously when the user confirms, because the alert clears `pendingRemoval` as it closes, before a task started from its button would run.

Lives in: `HermesMobile/Features/Settings/PluginsModel.swift`

## Render list status as a row so pull-to-refresh works

`ProvidersView` renders its loading, load-failure, and empty-catalog states as a full-height list row rather than an overlay, so pull-to-refresh keeps working.

Lives in: `HermesMobile/Features/Settings/ProvidersView.swift`

## Show connection errors under the password field

`BotConnectionView` shows its error under the password field, so the focused field's keyboard never covers it.

Lives in: `HermesMobile/Features/Bots/BotConnectionView.swift`

## Announce a busy toast's result to VoiceOver

When a busy `ActionToast` that waits for a VoiceOver user turns into a result, `ActionToastView` posts an accessibility announcement. An update keeps VoiceOver focus on the toast but isn't read on its own.

Lives in: `HermesMobile/Features/Shared/ActionToast.swift`

## Pass session list card inputs from @AppStorage

`SessionListCard.current(completedResponses:tipDismissedRelease:starDismissedRelease:usageReportConsent:...)` picks the card the session list shows on the device's standard defaults. The caller passes the stored counter, dismissed releases, and usage report answers from its `@AppStorage`, so reading them subscribes its view and an answer hides a card at once.

Lives in: `HermesMobile/Config/SessionListCardState.swift`
