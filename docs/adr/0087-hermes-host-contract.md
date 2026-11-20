# 0087. Hermes host contract quirks

Area: networking-hermes

## Let hosts without a readable version sign in

`HermesCompatibility.isSupported` treats a missing or unreadable `/api/status` version as supported: the pinned release always reports one, so its absence means a proxy or a fork, not an old host.

Lives in: `HermesMobile/Networking/Hermes/HermesCompatibility.swift`

## Send gui as the Hermes session source

`HermesCall.source` is `gui` (#1335, read at hermes-agent v0.22.5). It has no built-in platform note, and a standalone dashboard forwards a session PATCH to a separate gateway, which refuses one on a session it hasn't loaded unless its stored source is local (`hermes_state_mutation_binding.py` `authorize_history`); the earlier `hermex` answered 404 `{detail: "not_found"}` on every edit. The same `HermesREST` header records the verified shape of each route it builds, with its issue, the pin ca678285 and where it was checked (`scripts/local-hermes` or a live host), among them: push provisioning (#557), the plugins hub cached 5 s (#851), the restart route that changes the dashboard's session key about 2 s later (#934), cron routes and a trigger whose run outlives a dropped request (#1040, #1041, #1042), the session write fence's 409s (#1300), native sign-in tokens (#708) and the `.env` routes (#1318).

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`, `HermesMobile/Networking/Hermes/HermesCall.swift`

## Scope new sessions to the dashboard's current Profile

`GET /api/profiles/active` (#1010) answers `{active, current}`. `current` is the Profile this dashboard is scoped to, which a new session runs under; `active` is only the CLI's sticky default.

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`

## Escape + in Hermes query strings

The host reads a query's `+` as a space, while a path keeps its own. `HermesREST` rewrites `+` to `%2B` in the percent-encoded query of `downloadArtifact`, `sessionSearch`, `fsList`, `fsReadText` and the `pathQuery` GETs that name host paths, so a host path or a typed query such as "c++" reaches the host intact.

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`

## Ask the host's maximum limit for Bot Chat search

The host's session search has no offset to page with and no filter for the Bot Chat (#1146). The Bots inbox search asks for `HermesREST.sessionSearchMaximum`, so a Bot Chat behind 50 other matching sessions is still found.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`, `HermesMobileTests/BotInboxTests.swift`

## Don't gate the gateway migration on the plan's eligible flag

`HermesMigrationPlan` reads `GET /api/gateway/migrate/plan`, the preflight for serving every Profile from one gateway (#1611). It never gates on `eligible`: that is `hermes update`'s bar for migrating on its own, false on a host where no Profile runs its own gateway even when the migrate command works.

Lives in: `HermesMobile/Networking/Hermes/HermesProfileServing.swift`

## Require live_served to confirm a multiplexed gateway

`HermesMigrationPlan.servesEveryProfile` needs both upstream's `already_multiplexed` and the live gateway's `live_served` naming more than one Profile. `already_multiplexed` turns true as soon as the migration writes the flag; only the restarted multiplexer records `live_served`.

Lives in: `HermesMobile/Networking/Hermes/HermesProfileServing.swift`

## Re-mint a Connected Apps link whose account vanished

The host hands back a sign-in that is still open rather than a new one, keeping a cancelled sign-in open until its deadline even after its pending account was removed, and that link is dead: the portal answers 404. `HermesConnectedAppsClient.signIn` closes a link whose account the host no longer lists and asks once more, which mints a fresh one; `ConnectedAppsModel` relies on it.

Lives in: `HermesMobile/Networking/Hermes/HermesConnectedAppsClient.swift`, `HermesMobile/Features/Settings/ConnectedAppsModel.swift`, `HermesMobileTests/ConnectedAppsModelTests.swift`
