# 0084. Hermes connection logging

Area: networking-hermes

## Never log host identifiers in HermesConnection logs

`HermesConnectionLog` writes under the bundle ID and the category `HermesConnection`: sign-ins, the gateway socket opening, closing and dropping, a reply that matched no open call and a call that got no reply. Lines name connections `c1`, `c2`, … and each connection's sockets `s0`, `s1`, …, never the server, and interpolate only numbers, step, case and method names, the release `/api/status` reports (upstream's package version) and `reason(_:)`, each `privacy: .public`. Never a host, address, URL, session or runtime id, Profile name, title, message text, ticket, replay epoch or install id; events, deltas and keepalive pongs are never logged. `HermesConnectionLog.reason` names an error without its description or user info, because a `URLError`'s user info holds the failing URL, and so the host, and a rejection can carry the host's own text. `BotFailure`'s payloads are status and error codes and the release reported for `.outdated`; `.profileNotServed` carries a Profile name and the host's prose, so it is named without them.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Log a WebSocket's close code, never its reason

`NativeBotSocket.receive` logs the close code of a socket the other end closed, never its reason, because a proxy can put any bytes there. A refused upgrade fails the first read with a bare `URLError`, so the handshake's HTTP status, when there is one, says what refused it, and the gateway logs that failure.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`
