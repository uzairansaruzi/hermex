# 0081. Canonical gateway sessions

Area: networking-hermes

## Drop scope for yolo and fast on canonical hosts

On a canonical host a session-scoped bypass and Fast are the default, and the host refuses `scope: session` for either (#1602, #1604). `HermesCall.canonicalParams` removes `scope` from `config.set` for `yolo` and `fast`.

Lives in: `HermesMobile/Networking/Hermes/HermesCanonicalProtocol.swift`

## Hold a canonical session from the moment resume is sent

The host keeps one subscription per socket and session, so every screen attached to a session on the shared socket shares it: a second `session.resume` answers the same `subscription_id`. `HermesCanonicalSubscriptions` records which screens hold each session; a screen that leaves releases its hold, and only the last one's leaving sends `session.detach {session_id, subscription_id}`, so two chats on one session never detach each other. A screen holds a session from the moment its resume is sent, because the host answers frames in order and a detach sent while another screen's resume is in flight would end the subscription that resume just shared. A screen that leaves before its attach is answered still gets the reply's subscription detached when nobody else holds the session. Ids repeat across Profiles, so each session is keyed by its Profile too, and a new socket starts with none (`HermesGateway.end`).

Lives in: `HermesMobile/Networking/Hermes/HermesCanonicalProtocol.swift`

## Check canonical attach replies before settling the call

On a canonical socket `HermesGateway.consume` hands each reply to `HermesCanonicalSubscriptions.didAnswer` before the pending call is removed and settled, so an attach whose screen has already left is still detached.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`

## Answer canonical host requests with the JSON-RPC response frame

A canonical host takes a sudo value only as the response frame to its own request; its `request.answer` proxy says "expired" while the request still waits. A gateway Webapp likewise answers `request.answer` for a theme request with `expired` and lets it time out (captured at the pin). So a canonical Hermes chat never sends `request.answer` for these and answers with the response frame instead.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`, `HermesMobile/Features/Chat/HermesChatRequests.swift`, `HermesMobile/Features/Chat/HermesThemeRequest.swift`, `HermesMobileTests/HermesChatRequestTests.swift`

## Track attached runtimes so a delete can close them first

The host keeps a runtime after its screen leaves and refuses to delete a session any runtime holds, so a delete closes this phone's own idle runtime first. `HermesConnection.attachedRuntimes`, recorded by the gateway, holds every runtime a `session.resume` on this connection reached or a `session.branch` made (#1051) that no `session.close` here ended (#1048). It lasts as long as the connection, past any one socket, as the host's runtimes do; one the host has since reaped stays in it and is never in `session.active_list` again.

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`
