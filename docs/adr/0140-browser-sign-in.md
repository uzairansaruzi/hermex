# 0140. Browser sign-in

Area: settings-onboarding-auth

## Sign in to Hermes through a loopback listener and an ephemeral browser session

`HermesBrowserSignIn` signs a Hermes host in through the system browser (#708) as RFC 8252 describes for a native app: a loopback listener on `127.0.0.1`, the host's `/auth/native/authorize` in an ephemeral `ASWebAuthenticationSession`, and PKCE. The host brokers its own provider's pages (an OIDC IdP, or its `/login` form for a password provider) and redirects to the listener with a single-use code, which `HermesConnection.signIn(browserCode:verifier:)` trades for tokens. The onboarding and Add Server form and a Hermes server's sign-in form use it for a host whose status offers it (`HermesSignInMethod.offered(by:)`), on its own or picked over the host's password (#1539). A phone against a 0.21.5 host in the slice 8.1 spike showed that the HTTPS hop to the loopback port is never upgraded to HTTPS, the listener survives the app being suspended while the user is in a password manager, and the ephemeral session shows no "wants to use … to sign in" alert. A listener iOS reclaims shows a "can't connect" page in the sheet; closing it and signing in again recovers.

Lives in: `HermesMobile/Networking/Hermes/HermesBrowserSignIn.swift`

## Fully percent-encode the browser sign-in authorize URL

The `/auth/native/authorize` URL on `base` has every query value fully percent-encoded, since some proxies' filters refuse an unencoded `redirect_uri=http://…`. It sends no `provider`: the host picks its only interactive provider itself and shows its own chooser when it has several.

Lives in: `HermesMobile/Networking/Hermes/HermesBrowserSignIn.swift`

## Use a shared browser session for Nous Portal sign-in

The Nous Portal sign-in in Connected Apps is not ephemeral, so the sign-ins already in Safari carry over. It returns when the sheet closes, by the portal's return or by the user, and how it ended is not the answer: the host's accounts are, and the model reads them next.

Lives in: `HermesMobile/Features/Settings/ConnectedAppsView.swift`

## Return Connected Apps sign-ins on the hermes scheme

The portal's done page returns to `hermes://connections/done`. The host asks for the desktop app's return on every account sign-in and a client cannot name its own. An `ASWebAuthenticationSession` catches a scheme Hermex has not registered, which closes the sheet without handing the user to the official Hermes app, which has registered it (#1629's spike).

Lives in: `HermesMobile/Networking/Hermes/HermesConnectedAppsClient.swift`
