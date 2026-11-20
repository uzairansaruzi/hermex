# 0094. Remote screen socket

Area: networking-hermes

## Keep screen sockets alive with protocol pings

Cloudflare closes a quiet socket at about 100 s, and the screen bridge closes on any text frame. `RFBClient` therefore sends WebSocket protocol pings every `Options.keepalive` (25 s), never the gateway's JSON heartbeat; a ping that goes a whole period without its pong or any frame ends the stream as `.silent`.

Lives in: `HermesMobile/Networking/Screen/RFBClient.swift`

## Close screen sockets with 1011 to keep control

`NativeRFBSocket.close` never closes cleanly. The host hands control back when the holder's stream closes with 1000 or 1001, and only an explicit `display.lease.release` should do that, so leaving for a 2FA code keeps control. It cancels with 1011 (`.internalServerError`), a code the protocol allows an endpoint to send, which the host reads as a dropped link.

Lives in: `HermesMobile/Networking/Screen/RFBClient.swift`
