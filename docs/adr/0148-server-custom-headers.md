# 0148. Server custom headers and adding a server

Area: settings-onboarding-auth

## Probe a new server with its own headers

`AuthManager.addServer`, the in-app add-server flow, differs from `configure` (the onboarding path): it never mutates the active server's state or its live `CustomHeaderStore` until the add fully succeeds. `probeClientFactory` builds an `AuthAPIClient` bound to the new server's explicit headers, so a typo or an unreachable server can't bounce the user out of a working session, and the active server's concurrent requests (polling, SSE reconnect) never pick up the new server's headers during the async probe (#16, #17). It rejects a URL that's already configured (no duplicate normalized URLs). It commits only once the add succeeded, doing the throwing Keychain `serverURL` write before `headerStore.replace` so a write failure leaves the live header store and the active server untouched; the new server's headers then move into the live store and persist under its own scoped key (#16), while the previous server's headers stay in their own scoped Keychain entry.

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Hydrate custom headers before building any client

`AuthManager.hydrateCustomHeaders(for:)` loads a webui server's custom headers into the live snapshot before any client is built, so the first request after launch already carries them (#255). On the first launch after the per-server split there's no scoped entry yet, so it migrates the pre-#16 global blob in place, writing it under the scoped key and dropping the global remnant only once that write succeeds, so a failed write still applies the headers and retries on the next launch (#1785); the steady state costs one scoped Keychain read (#16). `AuthManager.enterActiveServer` relies on this, then enters `.loggedIn` optimistically: a stale cookie is demoted by the first 401 in `handleAPIError`. A Hermes server sends no webui headers and is signed in only while its own `BotConnection` record exists; without one its sign-in form shows (#899).

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Persist edited custom headers to the Keychain only on dismiss

`AuthManager.updateCustomHeaders(_:persist:)` always updates the in-memory `CustomHeaderStore` immediately, so live requests pick up edits, but the Keychain write is opt-in. The Settings editor calls it with `persist: false` on every keystroke and `persist: true` once on dismiss, because Keychain writes are slow enough to stutter typing (#255).

Lives in: `HermesMobile/Auth/AuthManager.swift`
