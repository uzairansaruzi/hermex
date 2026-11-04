# Bot Screen

Watching and controlling a host's screen from the phone (#1567). A screen is the place where
the bot's `computer_use` acts, and that place differs by host, so the app says which one the
user is looking at. It ships dark behind a per-server "Bot Screen (beta)" switch
(`BotScreenSettings`), on Hermes servers only.

## Parts

- `Networking/Screen/RFBDecoder`: RFB 3.8 bytes to a framebuffer. Knows nothing about sockets
  or Hermes, so recorded bytes drive it. Each step reads one whole message or rectangle and
  commits it; a step that runs out of bytes rolls back, because WebSocket frames (chunks of up
  to 64 KB) don't align with RFB messages.
- `Networking/Screen/RFBClient`: one stream, a socket plus the decoder, off the main actor. It
  waits for each frame to land before requesting the next, so one frame is ever in flight.
- `Features/Screen/ScreenSession`: an `@MainActor @Observable` owner of one open view. A
  generation token rejects anything late from before the last `open()` or `close()`.
- `ScreenSource`: where the picture comes from. Nothing above it branches on the host.
- `ScreenFrameStore` and `ScreenFramebufferView`: frames go straight to a `CALayer`, so a frame
  never invalidates SwiftUI.

Tight needs zlib. The SDK's `zlib` module autolinks the system `libz`, so it needs no project
setting and is no new dependency.

## Stock contract (`display.*`)

Read at `ca678285` (0.21.5) and `bf0203a7` (0.22.5), and run against stock 0.21.5 on a Linux
Codespace, over loopback and through its public address.

- `display.status`, `.observe` and the rest take `profile`. `.observe` mints a single-use 30 s
  ticket for `/api/display/ws?display_ticket=`, a `viewer_id`, and repeats the status fields.
- The handshake is RFB with security type None. The server's filter expects exactly
  12 + 1 + 1 client bytes, then framed messages, and forces the shared flag on.
- Only client types 0, 2, 3, 4, 5, 6, 150, 248, 251 and 255 are framed. Any other closes the
  stream with `1003`.
- Close codes: `4000` control taken, `4001` screen gone, `4401` bad ticket (observe again),
  `1003` protocol error. A policy refusal happens before accept, so it is an HTTP 403 on the
  upgrade.
- Every `display.*` failure is 5300. A refusal adds `data.code`, read first; with none it is a
  state, such as a stopped screen. -32601 means the host has no such method, which hides the
  entries (`ScreenCallFailure`).
- A busy Xvnc screen at the JPEG quality the client asks for sends Tight JPEG, palette and fill.
  It never sent gradient or plain zlib rectangles there, so those are tested on hand-built bytes.
- A screen stops after `bot_desktop.idle_stop_minutes` (30) with no viewer attached.

## Entries

The bot chat's toolbar, the Bots home row and tile menus (outside the edit-only group, which
`mayEdit` disables), ⌘⇧S for the selected bot, and `hermes-agent://bot?…&screen=1`. There is no
App Intent or Lock Screen control in v1.

## Testing against a Linux host

`scripts/local-hermes` on a Codespace, with a random password and `dashboard.public_url` set to
the address, because a Codespace holds repo credentials. Its port must be forwarded once
(`gh codespace ports forward`) before `gh codespace ports visibility <port>:public` finds it. A
plain desktop only produces solid fills, so run something busy before testing decoders.
