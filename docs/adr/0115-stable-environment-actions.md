# 0115. Stable environment actions

Area: performance

## Publish actions to chats as stable reference objects, not closures

SwiftUI cannot compare closures, so a closure rebuilt on each owner pass would invalidate every view that reads it. Actions published through the environment are references whose instance never changes, with a `handler` refreshed in place that nothing observes, so readers see the same value on every pass. `ChatDisclosureToggleAction` lets transcript disclosure controls (reasoning blocks, tool cards, tool groups, turn folds) call it right before they toggle so the transcript can pin the reader's offset and suspend follow scrolls through the size change; `chatDisclosureToggled(perform:)` keeps one instance, since a closure rebuilt on each transcript pass (every stream tick and keystroke) would invalidate every reader. `OpenNotificationSettingsAction` opens Settings at Notifications with the push section expanded; `SessionListView` installs it, so every chat it hosts inherits it (opened from the list, a new chat, a fork, or Archived Sessions). `HermesUpdateSignInAction` opens the Hermes server's sign-in form after its host refused the saved password (#942); `HermesServerHome` installs it for every Hermes chat under it (the Sessions list, a pushed branch or Archived Sessions), while a bot's chat takes the inbox's (#1146). `BotScreenOpener` opens a chat's Screen from its card or ⌘⇧S, taking over once it is live when `takingOver`, so a pass of the Bots home invalidates no chat.

Lives in: `HermesMobile/Features/Chat/ChatScrollPolicy.swift`, `HermesMobile/Config/NotificationOffer.swift`, `HermesMobile/ContentView.swift`, `HermesMobile/Features/Bots/BotScreenCard.swift`

## Keep stable action instances in the modifier's own state

The stable instances live in the installing modifiers' own `@State` (`ChatDisclosureToggledModifier`, `TranscriptLinkHandlerModifier`), not the caller's. Handlers usually capture the calling view, so keeping the instance in that view's state would make a cycle (state holds instance holds handler holds view) that outlives the screen.

Lives in: `HermesMobile/Features/Chat/ChatScrollPolicy.swift`

## Write the transcript openURL environment value once

`TranscriptLinksModifier` publishes the enclosing router's `openURL`. It takes no inputs and its one dependency never changes, so owner passes skip its body and `openURL` is written once. Re-written on every pass, iOS 26 could treat it as changed and re-run every link reader; `ChatTranscriptEnvironmentStabilityTests` guards this.

Lives in: `HermesMobile/Features/Chat/ChatScrollPolicy.swift`
