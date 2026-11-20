# 0086. Hermes gateway socket

Area: networking-hermes

## Send client.capabilities first on every gateway socket

Without `client.capabilities` the host treats the socket as a build that predates server-to-client requests: approvals are withdrawn unsent, clarify is answered empty, and sudo and secret prompts are skipped. `HermesGateway.handshake` sends `HermesCall.clientCapabilities` as the first frame after `gateway.ready` on every socket, reconnects included, with exactly the contract's one key. A host older than the capability answers -32601 and connects as before; the shared web client ignores any rejection here too, so only a lost socket fails the handshake.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`, `HermesMobileTests/BotClientTests.swift`

## Ping the gateway every 15 s to beat the silence deadline

The host sends no JSON heartbeat of its own, so an idle socket would hit the 45 s silence deadline in `receive`. `HermesGateway.startHeartbeat` sends `gateway.ping` every `Options.heartbeatInterval` (15 s), only after the handshake. The pong is just more inbound traffic: its string id matches no pending call, so `consume` drops it and it never settles an RPC. A failed send is a lost socket.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`, `HermesMobileTests/BotClientTests.swift`

## Close the gateway socket on .background only

`HermesGateway.closeForBackground` closes the socket when the app goes to the background (#902), so the host sees a clean close rather than a half-open socket the tunnel notices only at its idle cutoff. It is silent: no attached screen hears it, because each suspends on `.background` itself. The chat, inbox, rooms and editor reconnect on `.active` onto a fresh socket, ticket and handshake; the creators reconnect on their next Create. `ContentView` calls `HermesConnections.closeForBackground` on `.background` only, so Control Center and banners (`.inactive`) keep the socket.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`, `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Probe the gateway socket after a network path change

A network handover can leave the socket open but dead (#1372). `HermesGateway.probe` sends `gateway.ping`, and any frame within `Options.probeDeadline` (8 s) proves the socket alive; silence ends it as lost, so attached screens hear `.transport` once and reconnect onto one replacement. The ping is sent in its own task beside the deadline rather than before it, so a send that never returns can't hold the deadline off. Calls made while a probe runs wait on it; nothing happens while no socket is open or while it opens, and a leave, background, retirement or fault ends the probe early. `ContentView` calls `HermesConnections.networkPathDidChange` only while the app is not in the background and the path is satisfied: an unsatisfied path alone never closes a healthy socket, and the call never opens a connection or a socket.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`, `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Drop the gateway socket after a dashboard restart

After the dashboard restarts (#1075) its old socket can linger half-open behind a tunnel. `HermesGateway.dropSocket` ends the socket as lost, so attached screens hear `.transport` once and reconnect on their own, as after any drop. Nothing happens while no socket is open or opening.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`

## Use one Webapp socket per Profile

On a gateway's Webapp, `HermesConnection.profileGateways` gives each Profile's chats their own `HermesGateway` while one holds it (#1341, decision 2). Session ids repeat across Profiles, and a canonical session's events don't name their Profile, so one socket may carry only one Profile's sessions.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Confirm a Profile socket's 403 against the shared socket

The Webapp closes a Profile's socket before accepting it when its gateway doesn't serve that Profile, which the upgrade reads as a 403 (#1606). A proxy refusing sockets refuses the shared one too, so `HermesGateway.open` reports `BotFailure.profileNotServed` only after `HermesConnection.opensSharedSocket` succeeds. It then reads `HermesProfileServing` so the signed-in status says why, when the host gives a reason (#1611).

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`

## Forward gateway server requests in their original envelope

Server requests have string ids and no replay sequence. `HermesGateway.consume` forwards a frame with a string id and a method in its original JSON-RPC envelope rather than unwrapping it like an event, so screens cannot mistake it for a sequenced event.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`
