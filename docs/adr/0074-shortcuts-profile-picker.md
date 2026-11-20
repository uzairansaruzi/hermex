# 0074. Shortcuts profile picker

Area: live-activity-share-intents

## Cache profiles for the New Chat in Profile App Shortcut

Each profiles load in `SessionListViewModel` saves the list to `ProfileEntityCache.shared`, so the "New Chat in <Profile>" picker (#339) stays populated when Shortcuts resolves it in the background, where a live, authenticated fetch may not be possible. A nil `profiles` (field absent or undecoded) leaves the cache untouched, but an explicit empty list is forwarded so `save([])` clears a stale picker if the server ever reports none.

Lives in: `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Nudge App Shortcut parameters on first profile load each launch

iOS only indexes a parameterized App Shortcut once its suggested values exist, so without `HermexShortcuts.updateAppShortcutParameters()` the "New Chat in <Profile>" shortcut never appears while the parameter-less New Chat shortcuts do (#339). `ProfileEntityProvider.refreshAppShortcuts(changed:)` fires on the first profile load of each app launch, so the shortcut re-registers after a reinstall or index reset even when the list is unchanged, and on any later change, but not on every redundant reload, to avoid needless re-indexing.

Lives in: `HermesMobile/AppIntents/ProfileEntity.swift`, `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Read custom headers from the Keychain out of process

`ProfileEntityProvider.fetchLiveProfiles` is a best-effort live fetch that returns `[]` when no server is configured and throws on a network or auth failure so the caller falls back to cache. It runs in the App Intents process, where `CustomHeaderStore.shared`, which `AuthManager` hydrates only on a foreground launch, is empty. It reads the server's custom headers straight from the Keychain and passes them explicitly; otherwise a reverse proxy that authenticates on a header rejects the fetch and the picker never refreshes live. The session cookie is also absent out of process, so a cookie-auth server still falls back to the cache.

Lives in: `HermesMobile/AppIntents/ProfileEntity.swift`

## Clear the Shortcuts profile cache on server switch

The App Intents profile cache holds the previous server's profiles, which would leak into Shortcuts and Siri if the new server's fetch is delayed or fails (#339). `AuthManager` calls `ProfileEntityCache.shared.save([])` whenever the active server changes: in `addServer` and `addHermesServer` when the new server becomes active, in `switchActiveServer`, and in `advanceAfterRemoving`, where the cached profiles belong to the removed server whether the app switches to another one or returns to onboarding. The new server's profiles reload on the next foreground fetch.

Lives in: `HermesMobile/Auth/AuthManager.swift`
