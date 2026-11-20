# 0149. Server removal and sign-out

Area: settings-onboarding-auth

## Re-check the active server after sign-out awaits

`AuthManager.signOut` awaits push teardown and roster removal before it sets `.loggedOut`, and guards `state.server == active` first. Those awaits can outlast a switch to another server, which must stay on screen rather than be signed out.

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Discard move journals after the server's entry is gone

`AuthManager.removeServer` calls `MoveToHermesJournal.discard(sources:destinationID:)` last, after the registry entry is removed, so a Move to Hermes still running finds no record and writes nothing more (#1216).

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Keep webui cookies when clearing a Hermes server

`AuthManager.clearLocalArtifacts(for:)` deletes one server's local auth artifacts (its scoped custom headers, its Bot connection with that connection's cached avatars, shared sign-in and remembered Hermes Profile, and its cookies) without touching the registry or the global `server_url` key. A Hermes server's sign-in never uses the shared `HTTPCookieStorage`, so clearing a Hermes server leaves the cookies of a webui server on the same host. Its push pairing lives in the shared Keychain access group and is torn down by `PushRegistrar.forget`, which the removal paths await first.

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Ignore webui 401s while a Hermes server is active

`AuthManager.handleAPIError` returns early when the active server is a Hermes server. A webui 401 is never about a Hermes server's own sign-in, and a late reply from a webui screen a server switch left behind must not sign the Hermes server out (#899).

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Clear a removed server's cache before its registry entry

`MoveToHermesRemoval.remove` removes an account the way Settings does: it deletes its offline cache (`CacheStore.clearCache`) and drafts (`ChatDraftStore.discardDrafts`) on this iPhone first, while the caller's view and `modelContext` are still alive, and only then calls `AuthManager.removeServer` for the registry entry.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesModel.swift`
