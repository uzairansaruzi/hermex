# 0100. webui sign-in and sign-out

Area: networking-webui

## Derive unsupported sign-in from the OIDC and trusted-header flags

`AuthManager.unsupportedSignInMessage(for:)` says why the app cannot complete sign-in on its own, or returns nil when it can: there is no auth, the server already signed this client in, or a password login is available. It replaces an "auth on and password auth off means passkeys" inference that used to live in three places. Upstream `is_auth_enabled()` (`api/auth.py`) also covers OIDC and trusted-header auth, so that inference locked out working deployments and told them the wrong reason (#3). The function checks `oidcEnabled` and `trustedAuthEnabled` before falling back to the passkey message.

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Treat a missing passwordAuthEnabled as password sign-in

In `unsupportedSignInMessage(for:)`, a nil `passwordAuthEnabled` means an older server that does not report the field. The check falls through to the password path rather than block a working user; only an explicit `false` leads to the OIDC, trusted-header, or passkey messages.

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Treat logged_in as already signed in

In `AuthManager.configure`, an auth status with `logged_in` means the server already authenticated this client; trusted-header mode does it at the proxy. There is nothing to log in with, so the server is saved as signed in without a password step (#3).

Lives in: `HermesMobile/Auth/AuthManager.swift`

## Log out server-side before deleting the session cookie

`AuthManager.attemptBestEffortServerLogout` runs while the session cookie still exists, so a reachable server is logged out server-side before `clearLocalAuth()` deletes the cookie (#249). The request is best-effort and bounded by `logoutTimeout`; failure, timeout, or cancellation is ignored so an unreachable or slow server never blocks local sign-out and the caller can always return to onboarding.

Lives in: `HermesMobile/Auth/AuthManager.swift`
