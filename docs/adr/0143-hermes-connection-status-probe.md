# 0143. Hermes connection status probe

Area: settings-onboarding-auth

## Probe Hermes /api/status without credentials

The status check is one unauthenticated `GET /api/status` on its own short-lived session. It sends no cookies or credentials, so checking never counts against the host's sign-in limit. It sends only the saved Connection Headers, which a proxy such as Cloudflare Access needs even for this public route, and a redirect to another host drops them.

Lives in: `HermesMobile/Networking/Bots/BotProtocol.swift`

## Read public status without cookies

The first sign-in read goes out signed out for real. A gateway's Webapp answers a caller its cookies sign in with its install id, which would hide that it names the install only once signed in (#1606).

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Classify a public status 401 by its body

`/api/status` is public on every dashboard, so on the first sign-in read a 404, a body that is not JSON, or a 401 whose body is a JSON object (the webui's auth gate) means the address is something else, such as the webui. Any other 401 comes from something in front of Hermes, such as Cloudflare Access. The `onlyHostRefusalIs400` flag is the one `status()` sets.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Treat only the Host-header refusal as a dashboard 400

`HermesConnection.status()` reads the public `/api/status` once, with this connection's headers and no credentials, classified as sign-in classifies it: `.notDashboard`, `.blocked` or `.rejected`. The connect form reads it to tell a Hermes dashboard from a webui (#900). Its probe can reach a port the webui path never would, such as plain HTTP on a TLS port, so here only the dashboard's own Host-header refusal is `.rejected(400)` and any other 400 is `.notDashboard`. The read is this connection's attempt record, with only its status stage checked.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Read a Webapp's install id again after sign-in

A gateway's Webapp names its install only once signed in (#1606), so `HermesConnection` reads the install id again after sign-in and checks it before anything loads.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`
