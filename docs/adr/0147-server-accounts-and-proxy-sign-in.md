# 0147. Server accounts and proxy sign-in

Area: settings-onboarding-auth

## Keep custom headers through session expiry

A session-expiry sign-out (`AuthManager.handleAPIError` on `APIError.unauthorized`) keeps the server's scoped custom headers, so signing in again behind the proxy still works. A full sign-out forgets the server and its scoped headers.

Lives in: `HermesMobile/Auth/AuthManager.swift`, `HermesMobileTests/CustomHeaderInjectionTests.swift`

## Prefill custom headers only when onboarding signs in again

Because headers survive a session-expiry sign-out, `AddServerView` hands `authManager.currentCustomHeaders` to `OnboardingViewModel` only for the `.onboarding` entry, which fills them in again (they are empty on first run or after a full sign-out). Settings' Add Server passes none, so it never sees the active server's headers.

Lives in: `HermesMobile/Features/Settings/AddServerView.swift`

## Bind custom header rows by id

`CustomHeadersEditor` is the add/remove editor for custom request headers, shared by Add Server's Connection Options, a webui server's settings and a Hermes connection (#255). It binds directly to the header list and the owner decides when to persist. The owner may hide a row as it is edited (Connection Options moves Cloudflare Access's rows to their own fields), so rows bind by id, never by index (#1705). A row's binding finds the row with its snapshot's id wherever it now sits; once the row is gone it reads the snapshot and drops writes, so a field SwiftUI still holds can't read past the end of a list that just shrank.

Lives in: `HermesMobile/Features/Shared/CustomHeadersEditor.swift`

## Refuse connection headers Hermes or the transport owns

`HermesConnection` admits request headers for one direct-Hermes origin by the policy the host needs: no name the transport owns (the URL loading system, the cookie jar and the gateway handshake set those), and no name Hermes reads for its own checks (`Origin` for the gateway upgrade, `X-Forwarded-Prefix` for the session cookie's path, `X-Hermes-Session-Token`). It also refuses a `Bearer` authorization, which Hermes reads as its session token. Any other `Authorization` value passes, such as Cloudflare Access's single-header JSON service token, except on a browser sign-in's connection (#708), whose own bearer is its `Authorization`; there Access takes its two-header form. The only source is the Hermes connection's own record (`BotConnection.headers`, edited as Connection Headers in its form), never the webui's custom headers.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Don't read auth-on, password-off as passkey-only

`is_auth_enabled()` upstream covers password, OIDC and trusted-header, so "auth on, password off" on its own never meant passkeys (#3). `AuthStatusResponse` carries `oidcEnabled` and `trustedAuthEnabled`, and `AuthManager.unsupportedSignInMessage(for:)` returns nil for a server that already signed this client in. Trusted-header deployments, the reverse-proxy setups the custom-header feature exists for, authenticate at the proxy and answer `logged_in: true` with no password auth; reading that as passkeys shut them out of a server they were already signed in to.

Lives in: `HermesMobile/Models/ServerInfo.swift`, `HermesMobile/Auth/AuthManager.swift`, `HermesMobileTests/CustomHeaderInjectionTests.swift`

## Treat a missing password-auth flag as password login

Only an explicit `password_auth_enabled == false` can mark a server as one Hermex can't sign into (#255). An older server that reports `authEnabled` true but omits `passwordAuthEnabled` falls through to password login rather than being blocked as passkey-only.

Lives in: `HermesMobile/Auth/AuthManager.swift`, `HermesMobileTests/CustomHeaderInjectionTests.swift`

## Mirror server identity to defaults only on switch

When `ServerRegistry.activate(url:kind:serverVersion:)` re-activates an already-registered server, it mirrors that server's (possibly per-server-edited, #17) identity into the global identity defaults, so the existing `@AppStorage`-backed consumers follow the switch. It never mirrors on first insert: a new entry is seeded from those defaults, so writing back would change first-run identity for single-server users.

Lives in: `HermesMobile/Models/ServerAccount.swift`
