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
- `ScreenSource`: where the picture comes from, a bot's desktop or the host's. Nothing above it
  branches on the host except what it calls itself.
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

## Control

`ScreenSession` owns who controls the screen. A takeover survives anything but a deliberate end,
because upstream treats a clean socket close as a hand-back and a dropped one as "the human keeps
control", and a bot resuming into a half-typed login is the failure to avoid.

| Event while holding | Result | How |
| --- | --- | --- |
| Switch apps or lock the phone | Control stays, the stream stops | `suspend()`. `NativeRFBSocket.close` always sends 1011, never 1000 or 1001 |
| Connection lost | Control stays, the view retries | Backoff of 1, 2, 4, 8, 16, then 30 s |
| Return to the app | Control resumes with no prompt | A new socket mints a new viewer id. If the lease's hash matches the saved id, `display.lease.acquire` under the new one |
| Close the Screen | Hands back | `leave()`. The button says Hand Back while holding, and a failed hand-back also offers ✕, or a dead link would trap the user |
| Hand Back button | Hands back and stays, watching | `handBack()` |
| Switch servers, sign out, remove the server | Hands back | `ScreenHolds.handBackAll`, on a connection of its own so the tree's rebuild can't cut it off |
| Bot Screen switch off | Hands back, hides the feature | The same call |
| Another person takes over | Last wins, this viewer watches | Close code 4000 |
| 15 minutes with no input | Hands back | "Still there?" at 14. With the app away, a local notice, then `settleControl` or `ScreenHolds.reconcile` when it next runs |
| App killed and never reopened | The bot stays blocked | A stock lease never expires. Force Hand Back from any client, or `hermes computer-use screen stop --force` |

- The raw viewer id is a capability, so it lives in the Keychain (`ScreenHoldStore`), per server
  and Profile. The app compares `viewer_hash` against the first 12 hex characters of its SHA-256.
  It is saved before each acquire goes out, because a phone can suspend after the host took the
  lease and before the reply.
- Every hand-back names the saved id with `force: true`. `force` only skips the check that this
  connection minted the id; with an id, the host still releases only if that id holds, so it
  can't revoke another person's takeover. It answers success either way, so a hand-back counts
  only when the returned lease says this id no longer holds. `force` with no id clears any holder,
  and only the force Hand Back action sends that.
- Retaking control on return can race another person's takeover, because stock hosts have no
  conditional acquire. v1 accepts that window.
- A takeover this iPhone still holds shows on the Bots home (`heldScreenRow`), which is also where
  a hand-back that failed can be retried.

Both public proxies were checked with a holder's stream ending three ways, reading the lease 15 s
later. A TCP reset and a 1011 close kept control, and only a clean 1000 handed back, through a
Codespace's public address and a Cloudflare quick tunnel alike.

## Input

Input goes out only while this iPhone holds control and a stream is up; nothing queues across a
reconnect. `ScreenInputQueue` replaces a waiting pointer move and sends what piled up as one frame.

- Direct touch: tap clicks, hold right-clicks, two fingers scroll, pinch zooms, one finger pans.
- Trackpad panel: swipe moves, tap clicks, hold drags, two fingers scroll or right-click. The
  choice is per server (`BotScreenSettings.trackpadKey`).
- The iOS keyboard goes through `ScreenKeyField`, which stays empty so nothing typed is kept on the
  phone. Paste and password AutoFill arrive as text and go out a key at a time, so stock hosts
  never need ClientCutText.
- Modifiers from the key row latch and wrap only the next key or click, so none can stay down on
  the host. A hardware keyboard passes through as it happens (`ScreenHardwareKeys`).

## Setup on Linux

A screen that isn't running shows one state (`ScreenStatus.settledPhase`), the host's blocker first:
a sandbox short of its desktop image reports that as well as missing packages, and installing on
the host wouldn't fix it. That blocker shows in place of Start, in the host's words, as a refused
`display.start` does.

The app doesn't install anything or switch a sandbox's image. `display.install` needs `sudo` from
the phone, and switching the image recreates the container, so both stay on the host in v1. It
offers `status.install_command` to copy, which is the host's own line.

Stop Screen is in the toolbar's menu when this iPhone isn't holding. Over another person's takeover
it sends `force`, after a confirmation that says they lose it.

## The host's desktop (`hermex-screen`)

Mac and Windows hosts show their real logged-in desktop through
[`uzairansaruzi/hermex-screen`](https://github.com/uzairansaruzi/hermex-screen), built on the
`cua-driver` Hermes installs for `computer_use`. That repo's README and module docs own its
internals. Frames go directly between host and phone over the dashboard's address.

**Choosing the source.** Always `display.status` first. `supported` true is stock. False reads the
plugin's `GET /capabilities` (`HermexScreenPlugin.State`):

| Reply | Means | The app |
| --- | --- | --- |
| 200 | Routes are live, including a hot-mount on newer hosts | Streams, after `/status` |
| 404 `Plugin not found`, the whole message | Off or not installed | Offers the install, with consent |
| 404 `No such API endpoint…` or `Headless backend…`, on a second read | Enabled, not mounted | Offers a restart through hermex-push's route, or manual steps |
| 404 `Not Found` | A newer host tried to mount it and failed | Points to the dashboard log |

-32601 on `display.status` hides the feature. The app never branches on a version or an OS name;
what differs by OS comes from the plugin's own fields (`refusal`, `locked_input`).

**The plugin's contract** follows stock where it can, so `ScreenSession` runs one set of rules.
`POST /observe` mints a viewer id and a single-use ticket, a hold moves to a new id on return, and
Hand Back names the saved id with `force`. The stream takes the dashboard's own pass as `?ticket=`
plus `?stream_ticket=`. Close codes match stock, plus 4002: its own timer ended the takeover, or
another client handed back.

- A takeover holds every Profile's lease, because one desktop is every bot's. So it pauses every bot
  on that host.
- The plugin's timer hands back at 15 minutes with no phone connected, and survives a dashboard
  restart. The app's timer still runs while the view is open, for "Still there?".
- Install sends `ref`, a full commit (`HermexScreenPlugin.pinnedCommit`), so a fix reaches normal
  users through an app update. Testers can install a newer commit from the command line.
- "Check Again" only reads. Install, restart and remove each come from a confirmed tap.
- Hermes runs no plugin code on removal, so the app hands back first. On 0.22.5 the routes answer
  "Plugin not found" at once, and a reinstall hot-mounts again. If someone removes it another way,
  its leases stay held, `display.status` still shows them, and the force Hand Back clears each
  Profile's stock lease.

**The driver is whatever Hermes resolves.** On 0.22.5 that's a pinned 0.21.0, which has the
action-level `scope` this needs. A driver without it gets a plain explanation and no control. A
separately installed `/Applications/CuaDriver.app` can break Hermes's own: the pinned driver starts
that app's daemon, which refuses it. Moving it aside fixes that, and the grants carry over because
both have the same bundle identity. `hermes computer-use doctor` is the safe line to offer; it reads
only.

**Windows** is refused until the host sets `HERMEX_SCREEN_WINDOWS=1`, and `/doctor` says why. Testers
follow the plugin's `TESTING-WINDOWS.md`. The default flips in a new plugin commit that an app update
pins, after two testers pass.

## Entries

The bot chat's toolbar, the Bots home row and tile menus (outside the edit-only group, which
`mayEdit` disables), ⌘⇧S for the selected bot, and `hermes-agent://bot?…&screen=1`. There is no
App Intent or Lock Screen control in v1.

## Testing against a Linux host

`scripts/local-hermes` on a Codespace, with a random password and `dashboard.public_url` set to
the address, because a Codespace holds repo credentials. Its port must be forwarded once
(`gh codespace ports forward`) before `gh codespace ports visibility <port>:public` finds it. A
plain desktop only produces solid fills, so run something busy before testing decoders.
