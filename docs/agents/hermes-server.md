# Hermes server

How Hermex reaches a Hermes host: the sign-in, the one shared connection and its gateway
socket, the reconnect contract, feature detection and the compatibility pin. Every Hermes
surface goes through this, a webui server's optional Bots connection included.
`bots.md` owns what the screens do on top of it (chats, the inbox, rooms, Tasks,
Workspace, push provisioning); `hermes-feature-index.md` tracks which upstream methods and
gaps Hermex covers. AGENTS.md (Working with the server) owns the contract-verification
order and how to advance the pin.

## Sign-in and host identity

A Hermes server's sign-in is its direct-Hermes connection (below); a webui server can
keep one too, optionally, for its Bots. The connection is a Hermes dashboard's
HTTP/WebSocket backend, not webui.
The connection record, credentials and stable UUID live in server-scoped Keychain
storage. The host's identity is the `install_id` public `/api/status` reports (one
per Hermes root, so every Profile and every address that reaches it agree); the
record stores it the first time the host reports one (trust on first use; the inbox
backfills older records). A sign-in whose live id differs from the stored one
fails with `.differentHost` before the login POST, in `HermesConnection.signIn()`,
which every Bot surface and push provisioning goes through, so they all refuse
without sending the password. A missing stored or live id skips the check, and an
omitted id never clears a stored one. In the connection form, a new address or
username keeps the UUID when the host reports the stored `install_id`; otherwise a
different endpoint or username gets a new UUID. Password/name edits retain the
identity. After `.differentHost`, "Connect to this host instead" saves a new UUID
and discards the old connection's local data. The id is public: it catches an
address that now reaches another host, not an impostor. Removing the connection
deletes its drafts; removing the configured server deletes both its connection and
all its drafts.

## Server kind and home

A configured server is a webui server or a Hermes server (`ServerAccount.kind`, #899).
A Hermes server's id is its dashboard address as `BotConnection.address(_:)` parses it,
and its sign-in record is the same `BotConnection` JSON under `bot_connection::<its
URL>`, so every Bot store, draft, cache, section order and bot link keys by it as they
do by a webui server. `AuthManager.addHermesServer` saves a sign-in the form already
verified and activates the server, and refuses an address already in the registry.
Hermes is the default kind (#712), so nothing about a Hermes server needs Bot Mode:
adding one, moving a webui server to one, and opening one and its bot links all work
with it off. Its home (#709) has two sides on one stack
and one shared connection, the Bots inbox and the Sessions list, switched by a bottom bar
of `(filter) [Bots | Sessions] (new chat)` that each side fills: on Bots the filter holds
hidden bots and section order and new chat makes a bot or a group chat; on Sessions the
filter picks a Profile or All Profiles and new chat starts a session. Both sides lead with
webui's header (`SessionsHeader`): HERMEX, and one pill of search and the server's avatar
(Settings on tap, switching on hold), with no top bar. On Sessions the pill grows into the
search field; on Bots it opens the search sheet. The home keeps the inbox and the session
list's view model across the switch, so a switch shows the last roster or rows at once. It
reopens on the side last shown (`@SceneStorage`), Sessions at first, and a bot link turns it
to Bots. The two sides keep their own read marks, live states and identities. Without a
record (after Sign Out, which deletes the record and Bot data but keeps the server) or
after the host refuses its saved password at the login step, including the one silent
re-login a signed-in 401 starts (`HermesConnections.onSignInRejected`), the server is
`.loggedOut` and shows its connection form as the root: the address locked, the
password focused, no Remove, the avatar as the way out. No Bot screen exists in that
state, so nothing sends the refused password again; saving a sign-in signs the server
back in. A webui server's own connection keeps #884's per-screen flag instead. A
Hermes server sends no webui request: Settings skips its webui loads and hides their
rows, a webui 401 never signs it out, and webui's serverless session links (`session?id=`) and
bare-Profile New Chat in Profile links switch to the first webui server, or open nothing without
one. New chats (#1180) and shares (#1181) stay on it. It has no push pairing until #706,
so removing it never calls the relay. Its connection form is reached through Settings
→ Servers → the server → Hermes connection, and saving it signs the server back in. The
active Hermes server's page has both Sign Out of This Server, which keeps the server and
shows its sign-in form, and Remove Server. Moving a webui server's connection into a Hermes
server is #707's; a copy gets a fresh UUID.

## Connect form

Onboarding's Connect page and Settings → Add Server are one connect form
(`OnboardingViewModel`, #900). Its first Connect for an address reads the public
`/api/status` there, parsed by `BotConnection.address(_:)` and sent with the form's
headers on a `HermesConnection` of its own. A JSON object carrying the `auth_required` flag is a
Hermes dashboard, and `HermesSignInMethod` reads how it signs in: a password, the browser
(below) or none (below). For a password, username and password appear, and the next Connect signs in once
(`HermesConnection.signIn()`, so the version gate, install check and #880's copy apply),
then calls `addHermesServer`. Hermes' own Host-header 400 and `.blocked` show their
advice and stop, and a mode switch keeps that advice. Anything else, including an
address or headers only the webui path accepts, goes on to the webui path unchanged:
onboarding's `configure`, Add Server's `addServer`. Once a webui answered, the "Will
connect to" line shows `AuthManager.normalizedServerURL`'s URL instead of the Hermes
parser's. Header rows without a value are never sent or saved. When a webui server's own
Hermes connection uses exactly the same parsed address, the form offers "Use the sign-in
saved on <server>": it fills username, password and headers, and the sign-in still
expects that record's `install_id`. The copies stay until the address parses to another
URL, even one differing only in scheme, or a webui answers there; then the unedited
username and password and every header row still carrying a copied value leave the form.
It is never matched by `install_id`, which any host can report. The connection mode
(Same Wi-Fi, Private network, Cloudflare Tunnel) changes only the placeholder, the help
and, for Cloudflare Tunnel, two empty `CF-Access-Client-*` rows; it is not saved.

### Browser sign-in (#708)

A host whose status offers browser sign-in (`auth_flows ∋ native_pkce`) and no `basic`
password provider (`HermesBrowserSignIn.isRequired(by:)`) asks for no username or
password: the connect form and a Hermes server's own sign-in form (`BotConnectionSetup`,
which reads the server's status even when signed out) show "Sign In with Browser"
instead. It binds a loopback listener on `127.0.0.1` at an ephemeral port, opens the
host's `/auth/native/authorize` (S256 PKCE, `state`, every query value percent-encoded,
no `provider`: the host picks its only interactive provider itself and renders its own
chooser for several) in an ephemeral `ASWebAuthenticationSession`, and keeps the first
`GET /callback` whose `state` matches. The listener answers every callback `302
hermexsignin://done`, which closes the sheet. The code, single-use and valid for 120
seconds, goes straight to `/auth/native/token` (`HermesConnection.signIn(browserCode:verifier:)`),
which makes the form's connection a browser sign-in's (`BotConnection.oauth`, the host's
user id as username, no password) and signs in with the bearer, so the version gate,
install check and identity check apply. Closing the sheet shows nothing; a sheet closed
without a code or a refused code shows `.browserSignInFailed`. Signing the same account
in again from the server's form keeps the connection's UUID. A webui server's Bots
connection keeps to a password sign-in. Move to Hermes's host choice opens this same
form (#1266), which saves the destination as a Hermes server at once, without switching
to it, so a browser host can be a destination and its own connection rotates the token
the move then refreshes from (#1265). Not built: a
foreground rebind of the listener and a background task (on the 8.1 device the socket
survived 82 s of suspension; a reclaimed one shows "can't connect" in the sheet, and
signing in again recovers) and a revoke at sign-out (sign-out deletes the record and
its refresh token).

### No sign-in (#1314)

A dashboard bound to `127.0.0.1` without `dashboard.public_url` reports `auth_required:
false`; upstream runs without a password on no other bind. A phone reaches it only through
something that forwards to loopback, such as `tailscale serve`, Caddy or `cloudflared`.
The connect form and a Hermes server's own sign-in form hide the username and password,
enable Connect, and warn that anyone who reaches the address can use the agent; the
server's Settings page keeps that warning while its record has no username and no
browser sign-in (`BotConnection.hasNoCredentials`). Its sign-in reads the dashboard's page
(`GET /`, public, with the connection's headers), takes the token its script sets as
`window.__HERMES_SESSION_TOKEN__`, and proves it with a gated read
(`/api/profiles/active`): at the 0.21.5 pin `/api/auth/me` refuses this mode, since only
the password gate sets a session. The token is held in memory only and sent as
`X-Hermes-Session-Token`, never `Authorization: Bearer`, which a proxy's basic auth may
hold, and a cross-origin redirect drops it. `POST /api/auth/ws-ticket` is refused here,
so both socket upgrades present the token as `?token=` with no subprotocol
(`HermesREST.UpgradePass`), which the host checks without one
(`web_server_chat.py` `_ws_auth_reason`), each after a gated read. A host restart replaces
the token: the 401 that follows reads the page again and resends once, as for any
signed-in 401, and the read before an upgrade does the same, since a refused upgrade
can't say why. A record saved without credentials meeting the host with its sign-in on,
or one saved with credentials meeting it without, fails with `.signInChanged`, which signs
the active Hermes server out to its sign-in form, as a refused password does. The form saves
what the host now asks for, so only a record without credentials shows the open warning.

Debug and Hermex Branch builds have Settings → Testing → "Browser sign-in on password
hosts" (`HermesBrowserSignIn.isForcedForTesting`): a host that also offers `basic` then
signs in through the browser too, its `/login` form inside the sheet, which exercises
the whole path against a password host. It applies the next time a form reads the status.

The same connection form serves Bots, Settings and push setup. A schemeless
address defaults to HTTPS, except recognizable private/local IPs (including
Tailscale ranges), local names and single-label hosts use HTTP. Explicit schemes
and ports are preserved; TLS failures never trigger an HTTP downgrade. A pasted
link is reduced to its root: `ws`/`wss` become `http`/`https`, the query and
fragment are dropped, and a path starting with `login`, `auth`, `api`, `chat` or
`sessions` is removed; any other path (a proxy prefix) and credentials are refused.
While the text parses, the form shows the root it will connect to. Invalid
addresses display errors even before a transport exists. Cancellation invalidates
the attempt before late replies can save credentials or dismiss the screen.
The synchronous Keychain write is the commit point. Saved state changes with it;
old-connection cleanup then finishes independently of sheet cancellation and the
committed operation remains successful. Main-app ATS allows plain HTTP to `.local` and
single-label names through `NSAllowsLocalNetworking`, private/local and Tailscale IPs
through CIDR exceptions, and explicit `http://` Tailscale names through the `ts.net`
subdomain exception. Public hosts still require HTTPS.
A failed sign-in names what to check (`BotConnectionAdvice`): the unreachable host,
a Host-header 400 (`dashboard.public_url`), a webui address, a proxy or Cloudflare
status, an access proxy's own sign-in (`.blocked`: a redirect to another host or a
non-JSON 401 on `/api/status`), a host with no sign-in Hermex can use (`.browserSignIn`),
and a refused gateway upgrade (`.upgradeRefused`). The inbox and chat use the same
copy for the messages they show, and none of these three retries on its own.
A rejected password (`.rejected(401)`) offers "Update sign-in" in place of
Reconnect in the inbox, a chat and a room: it opens the connection form with the
password focused, from the inbox, because a chat's or room's client is bound to
the rejected record. The app never resends that password on its own; foregrounding,
pull to refresh and closing the form unsaved send nothing until the saved record
changes or the form saves a sign-in.

## The shared connection

The saved connection's HTTP side is one `HermesConnection` (`Networking/Hermes/`):
an ephemeral cookie jar, a single-flight sign-in, and the only path Bot HTTP
requests and gateway upgrades are sent through. `HermesConnections` gives every
consumer of the active server's saved connection (inbox, chats, rooms, creator,
editor and push provisioning's `BotDashboardClient`) the same instance, so they sign
in once; a reconnect only mints a new ticket, or checks an open dashboard's page token. The registry holds its one entry weakly
and keys it by configured server and connection UUID. A request for another server
or UUID, or for the same UUID with a new address, account, password or headers,
retires the old connection first: its sign-in in flight stops and its late replies
throw `.stale`. Switching away from, signing out of or removing the configured server,
and saving other credentials or headers or removing them, retire it at once rather than
at the next lookup, so a sign-in finishing afterwards stores nothing and resends nothing; a
rename or an install id backfill keeps it. Nothing is pooled by hostname, so the same host and account under two
configured servers get two jars. The connection form and dev auto-login probe
unsaved credentials on their own `HermesConnection`, never the shared one.
Cancelling one waiting consumer never cancels the shared sign-in. A signed-in
request answered 401 signs in again once, sharing that sign-in with every other
consumer's 401, and is resent: the auth gate refuses `/api/*` before any handler
runs (`hermes_cli/dashboard_auth/middleware.py`), so the resend cannot repeat a
write. A Bot screen's delete, upload or download is sent, and resent, only while
that screen still owns it: one that closed during the sign-in sends nothing. A 401 from the login itself (bad credentials) ends the recovery and leaves
the connection signed out; the next request signs in again. A transport failure,
proxy status or 5xx fails only its request and leaves the sign-in as it was, and
is never resent. Provisioning keeps its 120/180-second deadlines, for its steps and
for a sign-in it starts, on a second session that shares the jar; everything else
keeps 15/30.

A connection signed in through the host's browser sign-in (#708) keeps
`BotConnection.oauth` (provider, user id and refresh token) in its record instead of a
password. Its sign-in posts the refresh token to `/auth/native/refresh`, saves the
rotated one (`BotConnectionStore.saveRotatedRefreshToken`, only while the record is still
that connection holding that token) before the access token is used, and sends the
access token, held in memory only, as `Authorization: Bearer` on every signed-in request;
the socket upgrades still present a ticket. Each launch refreshes once, and a signed-in
401 refreshes again and resends, as a password connection signs in again. A connection
reads the refresh token from the Keychain, never from a copy of the record, before its
first refresh and before any later one after another connection saved a newer token, and
`adopt` ignores it. Move to Hermes refreshes on a connection of its own beside the
server's (#1265), and the two share the saved token this way. Retiring a connection never
cancels its refresh in flight (the host may already have rotated the token), and every
other connection on that server, whenever it was made, waits for it to save before its next
refresh reads the token. A save that fails is retried at the next
rotation. A 401 from the refresh is `.signInExpired`, which signs the active
Hermes server out to its sign-in form. No extension or App Intent signs in to Hermes, so
the app is the token's only user.

## Connection Headers

Connection Headers, for a proxy such as Cloudflare Access, are saved in the
connection's own Keychain record (`BotConnection.headers`) and edited from the
connection form with the shared `CustomHeadersEditor`. `HermesConnection` sends them,
as `HermesHeaders`, on every request to its own origin: the public `/api/status`,
sign-in, identity, ticket, REST and plugin calls, uploads, downloads, and both socket
upgrades: the gateway's `/api/ws` and the Kanban event socket (#1045), each on its own
ticket. The status probe sends them too, and the form signs its unsaved candidate in
with the form's set. A cross-origin redirect drops them before the push relay or any
other host, and `PushRelayClient` never sees them. The policy refuses transport names
(`Host`, `Cookie`, `Sec-WebSocket-*` and similar), the names Hermes reads for its own
checks (`Origin`, `X-Forwarded-Prefix`, `X-Hermes-Session-Token`) and `Bearer`
authorization while allowing Cloudflare Access's JSON `Authorization` form; the form
says why under the row and keeps Connect off. Only one of `CF-Access-Client-Id` and
`CF-Access-Client-Secret` warns but still connects. A header change keeps the UUID,
and with it drafts, cache and push pairing; it only retires the live connection. A
saved list the policy later refuses sends none. The webui's custom headers are a source
only on a tap: opened from Move to Hermes, the form offers "Use <webui server>'s
Headers", which fills that server's rows in visibly (#1266). The address is never
copied. Headers are never logged.

A browser sign-in's own bearer is its `Authorization`, so on that connection the policy
refuses any custom `Authorization`, Cloudflare Access's JSON form included; Access takes
its two-header `CF-Access-Client-Id` and `CF-Access-Client-Secret` form there. The browser
leg can't carry Connection Headers at all (`ASWebAuthenticationSession`'s extra headers
reach only the first load, and only `X-` names), so a proxy that gates on headers needs
its own sign-in inside the browser sheet.

## The gateway socket

Each `HermesConnection` also owns the one gateway WebSocket its Bot screens share,
`HermesGateway`. Every screen holds its own `BotClient` handle on it: the inbox, each
open chat (its controls and delegated work use the chat's), a room, the creator and
the editor. The socket opens when the first screen connects and closes when the last
one leaves, so it lives while any Bot screen is connected. Each screen leaves on
`.background` only, not on `.inactive`: Control Center or a notification banner keeps
the socket and its frames, which is cheaper than a reconnect and keeps a running turn's
tool rows in place. On `.background`, `ContentView` also has `HermesConnections` close
the socket once, silently (`closeForBackground()`), so the host sees a clean close
rather than a half-open socket the tunnel notices only at its idle cutoff. The chat,
inbox, rooms and editor reconnect on `.active`, onto one fresh socket with a new ticket
and one handshake; the creators reconnect on their next Create (#902).
Screens that connect while it opens wait for that one attempt, so screens
reconnecting after the same drop make one socket, one ticket and one handshake. A
reply settles only the call that sent it; every event and server request goes to
every attached screen, which admits only its own (a chat by its runtime ID, the inbox
`sessions.changed`), and the gateway never answers a server request itself. A screen's
`close()` fails only its own calls with `.transport`, cancels its uploads and
downloads and ends its callbacks; the last screen to leave closes the socket without
a disconnect. Cancelling a read discards its reply; cancelling a call that may have
reached the agent ends that screen's part as `close()` does and leaves the socket to
the others. A required call past its deadline ends only its screen, which hears
`onDisconnect(.transport)` once and reconnects onto the socket the others kept. A lost
socket (a read or send failure, 45 seconds of silence) is connection-wide: each
attached screen hears `onDisconnect` once and reconnects as before, and anything later
from that socket is dropped by its generation. Retiring the connection does the same with `.stale` and refuses
reconnects. A chat's session stays attached to the shared socket after the chat
leaves, until the socket closes; leaving a screen never closes a host session. The
connection form and dev auto-login probe on their own connection, so their own socket.

## Logging

`HermesConnection` and `HermesGateway` log the connection's lifecycle to the device
log (`HermesConnectionLog`), under the bundle ID and the category `HermesConnection`:
each sign-in with its release, or the step that failed (`status`, `login`, `identity`,
`ticket`) and why; the socket opening or failing to open (a refused upgrade with its
status); a drop with its reason and any close code the other end sent; 45 seconds of
silence; the last screen leaving; the app going to the background; retirement; a reply that matched no open call; and a
call past its deadline, by method. Lines name connections `c1`, `c2`, … and each
connection's sockets `s0`, `s1`, …, never the server: interpolate only numbers, step,
case and method names, the release `/api/status` reports (upstream's package version) and
`HermesConnectionLog.reason(_:)`, each `.public`, and never a host, address, URL,
session or runtime id, Profile name, title, message text, ticket, replay epoch or
install id. Events, deltas and keepalive pongs are never logged. `HermesConversation` logs
through the same logger, counts and codes only: each reattach (automatic retries before
it, and frames held, applied and dropped) and each `session.resume` refusal it retries.

## Typed requests

Requests are typed in `Networking/Hermes/`: every HTTP request (method, path, query, JSON body) is a
`HermesREST` case, and every JSON-RPC request is a `HermesCall` case, one per
operation the app uses and none for any other upstream method. A case carries only
what callers vary; fixed contract values (the canonical title, `queued`, the avatar
asset) are encoded there. `HermesCall.params()` is the only way to the wire and
runs admission first, so the "typed exception" rules in `bots.md` hold for every caller;
`HermesGateway` still runs `validateDispatch` at the socket write and maps errors,
cancellation and timeouts. Password login requires the basic auth gate, verifies identity,
and each socket gets a fresh single-use ticket, or on a dashboard with no sign-in its page
token as `?token=` (§ No sign-in). The upgrade is a `URLRequest`
(`HermesREST.gatewayUpgrade`) offering the `hermes-gateway-v1` and ticket
subprotocols in its `Sec-WebSocket-Protocol` header, which is where
`URLSessionWebSocketTask` takes them from a request; the host splits that header
on commas (`hermes_cli/web_server_chat.py`). JSON-RPC uses text frames. There is no bootstrap-token,
OAuth, webui fallback, server provisioning or competing-backend path.

## The agent's surface note

The host tells each agent what screen it writes to through a per-surface note in its system
prompt, picked by the session's `source`. A session with none runs as `tui`, whose note says
`MEDIA:` tags print as text and files must be delivered as paths. So every `session.create` and
`session.resume` Hermex sends carries `source: "hermex"` (`HermesCall.source`), and a branch
inherits its parent's. The host has no built-in note for that name, so Hermex keeps its own in
each Profile's config as `platform_hints.hermex.append` (`HermesREST.platformNote`), which the
host appends for that source (#1278). `HermesConnection.keepPlatformNote` reads the config once
per Profile per sign-in, before the first attach and before a new bot's chat is made, and writes
the note only when it is missing or different. `PUT /api/config` deep-merges, so nothing else in
the file changes. The note is read when the host builds an agent, so a runtime the host built
earlier keeps the old note until the host reaps it. Hermex owns `append`: a user's own text for
Hermex sessions goes in `platform_hints.hermex.replace`, which the host puts before it.

## Handshake

Every socket, reconnects included, runs the same handshake before any other RPC:
wait for `gateway.ready` (recording `replay_epoch`), then send
`client.capabilities {server_requests: true}`. From 0.21.4 the host refuses
every server request (approval withdrawn, clarify answered empty, sudo and
secret skipped) for a session whose only attached WebSocket clients never sent
it (`tui_gateway/server_requests.py`, `session_transports.py`). A host older
than the capability answers -32601; `connect()` ignores any JSON-RPC rejection
here, as the shared web client does, and connects as before. The host sends no
JSON heartbeat of its own (`heartbeat: true` in `gateway.ready` only means the
socket answers pings), so `HermesGateway` sends `gateway.ping` every 15 seconds
with string ids that never settle an RPC. Any inbound frame resets the 45-second
silence deadline; a socket quiet for longer is dropped and reconnects.

## Pin and minimum release

`HERMES_AGENT_TESTED_SHA` at the repo root pins the tested hermes-agent commit
(line 1) and the release `/api/status` reports as `version` (line 2), the Bot
counterpart of `UPSTREAM_TESTED_SHA`. The pin is 0.21.5 (`ca678285`); sections
of these docs that name an older commit record what was verified at the time. `BotClient.connect()` captures `version`
and the connection screen stores it on the `BotConnection` record.
`HermesCompatibility` holds the tested release and the minimum, 0.21.3: 0.21.2
publishes no gateway contract. `HermesConnection` compares the leading
`MAJOR.MINOR.PATCH` (a canary reads as its base release) right after the
`/api/status` read and refuses an older host with `BotFailure.outdated` before the
install check and the password, so the form, inbox, chats, rooms and push setup all
show the "update Hermes" copy. A missing or unreadable version proceeds: the pin
always reports one, so its absence means a proxy or a fork. At or above the
minimum, sign-in saves and dismisses whatever the release; no version warning is
shown (#626).

Each RPC validates the contract just in time. Advancing the pin is described in AGENTS.md
(Working with the server); update the file and the constant together, then run
`scripts/capture-hermes-fixtures`. It records what the host really sends for
`/api/status`, `profiles.list`, `session.resume` and one plain turn's event
frames into `HermesMobileTests/Fixtures/HermesAgent/`, and
`HermesAgentFixtureTests` feeds them through the real parsers, so a renamed or
dropped field fails a test instead of blanking a screen. The capture keeps only
the `inbox-triage` Profile, replaces every string outside an allow-list of ids,
event and status vocabulary, the release and the canned turn's text, and writes
nothing if the output still holds the host, the account, the socket ticket, a
home path, the install id or another Profile's name. `--keep-raw` and
`--from-raw` re-sanitize one capture without another live session.

## Reconnect contract

`HermesConversation` (`bots.md`) runs one path for every attach and reattach, so a first
open, a foreground and a dropped socket recover the same way. The session keeps two ids:
the stored key, which Hermex caches, links and drafts by, and the runtime id, which keys
session-scoped calls and `seq`, changes after a reap, and is never kept.

An attach reads, in order: `session.list` for a bot's chat (`session.create` once for a new
session), an identity `session.resume` with `omit_messages`, `session.events.since` from the
last `seq`, then one more `session.resume` for live state, also without the transcript: the
chat reads its settled rows from REST pages (#1047). While attaching, this runtime's live
frames are held (#901), up to the 512 events the host's replay ring keeps, and handed over
once the snapshot is in: a frame at or below the replay's `latest_seq` is dropped, and a
later one takes the live path, where a gap is the owner's rebuild signal. Past 512 the held
frames are dropped and the owner rebuilds, as after a truncated replay. Host requests
(string ids) are never held. A held `request.cancel` or `connection.*` frame keeps the
snapshot from replacing the cards, as a live one does, so a card withdrawn mid-recovery
keeps its note. Replay detects discontinuity but never appends text to an overlapping
snapshot. Live recovery never reads the local search cache and has no speculative REST
adapter.
Transient socket loss reconnects silently while the chat is active, with delays
of 1, 2, 4, 8, 16 and then at most 30 seconds. `session.resume` answering 4007
(swapping in a replacement runtime) or 4009 (a client-gone interrupt settling)
is retried the same way for 60 seconds from the first refusal in a row, then
shows the usual advice. It is matched by code alone: a real "session not found"
is also 4007, and costs at most that minute. The same codes from other calls
are not retried. Leaving the screen or backgrounding
cancels recovery. Foreground/recovery reloads canonical identity, history and
current state before enabling commands. Authentication, identity and unsupported
host errors still surface actionable messages; commands are never retried.

## Connection status

With a saved connection, the screen's Status section reads the public `/api/status`
once when the form opens or on "Check again" (no credentials or cookies, only the
saved Connection Headers; no retries) and shows the live
version (or the stored one), gateway state and platform counts; scheduled Tasks need
the gateway, Bot chat notifications do not.

## Feature detection

A host that answers a call with -32601 (method not found) lacks that method:
`HermesGateway` records it on the connection (`unavailableMethods`, never for the
handshake's own `client.capabilities`), and `BotChatControls` and a Hermes chat's
automations (`session.control`) read it, so a chat control the host lacks stays off in every chat on that connection until a new
connection starts empty.
An ordinary 4000 (invalid params) is not that signal. To learn whether a method
exists before calling it, the first consumer that needs to (#701 onward) sends a
deliberately invalid-parameter probe, `{"__hermex_probe": true}`: 4000 means
present, -32601 absent. Nothing sends one yet.

Every other check is a probe whose answer the app already understands. There is no
describe RPC, and `gateway.ready` lists no methods.

| Probe | Answer | Meaning |
| :--- | :--- | :--- |
| `GET /api/status` (public) | JSON object carrying the `auth_required` flag | A Hermes dashboard; its `version` meets the minimum or the sign-in stops (connect form, `HermesConnection.signIn()`). `false` signs in with the page's token (§ No sign-in). |
| `GET /api/status` | Hermes' Host-header 400, or `.blocked` (an access proxy's own sign-in) | The connect form shows its advice and stops; it does not try webui. |
| `GET /api/status` | anything else | Not Hermes: the connect form goes on to the webui path. |
| `client.capabilities` in the handshake | -32601 | A host before 0.21.4; connect anyway. |
| Any RPC | -32601 | The method is absent: `unavailableMethods`, and its control stays off. |
| Any RPC with `{"__hermex_probe": true}` | 4000 / -32601 | The method exists / is absent, without running it. Unused so far. |
| A session-scoped RPC | 4001 | The runtime was reaped: reattach to the stored key. |
| `groups.capabilities` | a capability missing | Rooms hide, or their writes turn off (`bots.md` § Group rooms). |
| `GET /api/plugins/<name>/…` | 404 `{"detail": "Plugin not found"}` | The plugin is off or not installed (`HermexPushPlugin.missingRoute`, Kanban). |
| `GET /api/plugins/<name>/…` | 404 `{"detail": "No such API endpoint: …"}` | The dashboard never mounted the plugin's routes: it is new on disk and the host needs a restart, or the host lacks it (`kanban.md`, Absent plugin). |
| `GET /api/plugins/hermex-push/capabilities` | `{plugin_version, routes}` / any 404 | The companion routes the loaded plugin mounts / none, so the feature doesn't show (`bots.md` § Push provisioning). |
| `GET /api/sessions/{id}/mutation-snapshot` | 200 / a catch-all 404 (`No such API endpoint`, or `serve`'s `Headless backend`) | The host fences session writes / it is older and takes them bare (§ Session write fence). |

## Session write fence

hermes-agent fences REST session writes (#1300): `PATCH /api/sessions/{id}` and
`POST /api/sessions/import` must carry `request_id` and `expected_revision`, or the host answers
409 `client_upgrade_required` (neither) or `mutation_identity_required` (one). `BotClient` sends a
fresh UUID as `request_id` on every write. A PATCH's `expected_revision` is the session's
`runtime_revision`, read from `mutation-snapshot` right before the write, because any activity on
the session moves it and a cached list row's value goes stale. An import always sends 0, the
revision of an anchor id the host doesn't have. Hermex never sends `expected_generation`. When the
snapshot route answers a catch-all 404 (`hermes dashboard`'s "No such API endpoint" or `hermes serve`'s
"Headless backend…"), the host predates the fence and the PATCH goes out bare;
older hosts ignore the extra fields on an import. A 409 (`revision_conflict`, `stale_generation`,
`admission_conflict`, `session_busy`, or an upgrade reason) is a `HermesSessionFenceRefusal` and is
never resent: the row action rolls back and reloads, and Move to Hermes leaves the batch uncertain
for its next run.

## Plugin routes need a host restart

The dashboard mounts plugin routers once, when its process starts
(`_mount_plugin_api_routes` in `hermes_cli/web_server.py`); a plugin disabled while it runs
keeps its router until then, behind a per-request gate. `POST /api/gateway/restart`
restarts only the messaging gateway, so a new or updated plugin's routes appear only
after `hermes dashboard` restarts. hermex-push 0.4.0 and newer mounts its own restart
route (#934); anything older costs the user one restart on the host. A plugin adds REST
routes, hooks, tools and its own sockets, but no RPC method and no `/api/ws` event, so a
gap the companion plugin fills is always a REST route, and each new route costs a
restart: ship them in batches, and gate each feature on `/capabilities`, never on a
version number.
