# Bot Mode

Bots use the selected configured Hermex server's optional direct-Hermes connection.
The connection is a separate Hermes Desktop HTTP/WebSocket backend, not webui.
The connection record, credentials and stable UUID live in server-scoped Keychain
storage. A different endpoint or username gets a new UUID. Password/name edits
retain the identity. Removing the connection deletes its drafts; removing the
configured server deletes both its connection and all its drafts.

`BotClient` owns an ephemeral cookie session and one WebSocket. HTTP paths live in
`BotEndpoint`. Password login requires the basic auth gate, verifies identity,
and mints a fresh single-use ticket for each socket. JSON-RPC uses text frames
with the `hermes-gateway-v1` and ticket subprotocols. There is no bootstrap-token,
OAuth, webui fallback, server provisioning or competing-backend path.

`HERMES_AGENT_TESTED_SHA` at the repo root pins the tested hermes-agent commit
(line 1) and the release `/api/status` reports as `version` (line 2), the Bot
counterpart of `UPSTREAM_TESTED_SHA`. `BotClient.connect()` captures `version`
and the connection screen stores it on the `BotConnection` record. Successful
sign-in saves and dismisses regardless of version; no version warning is shown.
Each RPC validates the contract just in time. Advancing the pin is described in AGENTS.md
(Working with the server); update the file and the constant together.

The disconnected inbox offers one Connect action with the editor's drawn,
neutral-default playful faces. Motion pauses while covered or inactive and is
still with Reduce Motion. Setup help copies a generic prompt for the user's
agent; copying sends nothing and includes no credentials or configured address.
The prompt discovers the existing backend and asks before changing setup.
The same connection form serves Bots, Settings and push setup. A schemeless
address defaults to HTTPS, except recognizable private/local IPs (including
Tailscale ranges), local names and single-label hosts use HTTP. Explicit schemes
and ports are preserved; TLS failures never trigger an HTTP downgrade. Invalid
addresses display errors even before a transport exists. Cancellation invalidates
the attempt before late replies can save credentials or dismiss the screen.
The synchronous Keychain write is the commit point. Saved state changes with it;
old-connection cleanup then finishes independently of sheet cancellation and the
committed operation remains successful. Main-app ATS exceptions cover the same
private/local IP ranges used by scheme inference; public hosts still require HTTPS.

`BotConversation` owns one server/connection/Profile view lifetime. It resolves
exact-title Bot Chat, keeps canonical root, compression tip and runtime IDs
separate, and rejects a changed root before resume. Lookup can recover archived
history; resume can auto-continue unfinished backend work. Neither is guaranteed
to be read-only.

Live history is rebuilt from a full resume snapshot on open/recovery. A separate
read-only local cache supports message search; see Local search below.
Replay detects discontinuity but never appends text to an overlapping snapshot.
Live events coalesce inflight snapshot reads using `omit_messages`; that installed
handler path avoids history database reads. Completion and session-state events
request full history. Live recovery never reads the local search cache and has
no speculative REST adapter.
Transient socket loss reconnects silently while the chat is active, with delays
of 1, 2, 4, 8, 16 and then at most 30 seconds. Leaving the screen or backgrounding
cancels recovery. Foreground/recovery reloads canonical identity, history and
current state before enabling commands. Authentication, identity and unsupported
host errors still surface actionable messages; commands are never retried.

The transcript follows a stable trailing anchor until the user scrolls into
history; the shared Sessions down-arrow resumes following. Its visibility uses
Sessions’ scroll observer, follow latch and near-bottom thresholds,
so it disappears on reaching the bottom. Coalesced text snapshots use synchronous
Markdown rendering without token reveal animations. The deferred streaming
renderer can leave a growing Bot response's trailing viewport blank; an XCTest
renders evolving snapshots and checks the actual visible output.

Settled messages reuse the Sessions transcript's long-press seam.
`chatMessageContextMenu` supplies the menu from a plain
`[ChatMessageActionItem]`, so a transcript names its own actions without owning
a chat view model; `BotMessageActions` builds that list, and for a Bot it is
Copy alone over the Markdown source, because the host owns the history and
edit, regenerate and branch have nothing to act on. Group rooms use the same
seam.

Settled bot replies and room member messages sit in a `ResponseTextSelection`
document, so text selects in place as it does in Sessions. The scroll-view
context menu outranks the selection long-press, so those rows pass
`longPress: false`: Copy stays a VoiceOver action and the selection menu
supplies Copy and Select All. User messages and the live reply keep the
long-press menu; the live reply is never selectable, because its document would
be rebuilt on every snapshot. "Ask Hermex" appends a `ComposerQuote` to the Bot
draft, durable through `ChatDraftStore`, and becomes a Markdown blockquote only
on the way out, after any skill expansion, so a failed send restores the
composer exactly. Rooms pass no Ask Hermex handler and the menu omits it. The
quote detail view stays in issue #564.

Both transcripts are eager `VStack`s because of that document. It is a hosted
view controller, and a lazy stack places rows it has not built from an
estimate: under load the latest-edge follow and a room's jump to a search hit
landed on the wrong rows (`testLongInflightResponseRemainsVisibleAtLatestEdge`,
`testRoomSearchHitScrollsToItsSequenceAndDoesNotFollowNewMessages`, the latter
on a cold first iteration). Eager is affordable only over a bounded list,
which is what incident #463 was about: `BotTranscriptWindow` draws the latest
50 settled messages with Load earlier above them, the way Sessions pages, and
rooms are bounded by their own Load earlier. The host still sends the whole
history; the window limits only what is built.

Activity comes from two sources that never overlap. The full snapshot's
`messages` rows already carry settled tool rows (`role: tool` with `name`,
`context`, `args`) and assistant `reasoning`; `BotTranscriptProjection` turns
them into `BotSettledActivity` anchored to the message each block precedes,
keeping the `<root>/<row index>` identity. The live turn reduces gateway events
in `BotTurnActivity`: `tool.start`/`tool.complete` keyed by `tool_id`,
`thinking.delta`/`reasoning.delta`/`reasoning.available`, keyed
`notification.show`/`clear`, and `review.summary` memory notes, bounded to 64
rows, 32 KB of reasoning and 8 notices. `todo.updated` and the snapshot's
`todo_state` feed a revision-monotonic `BotPlan`; `status.update` feeds
`workStatus`. Activity events during known work update local state without a
snapshot read. Replay rebuilds the current turn's rows when the sequence is
continuous, or from the last `message.start` the ring still holds; otherwise the
live rows are dropped and the next full snapshot shows the settled ones, so
overlap never duplicates a card. Presentation reuses the Sessions log rows
(`ReasoningBlockView`, `ToolActivityGroupView`, `TranscriptLogRowView`) and the
global Chat display toggles; the plan row stays visible with cards off. Tool
output is text only. `message.react` and `learning.frames` are deliberately
not wired: the snapshot carries no reactions to show back, and the frames are
terminal-sized renders.

Delegated work stays attached to its owning Bot conversation. A toolbar count
appears only while `subagent.list({session_id})` reports live workers; it opens a
sheet with at most 64 rows showing the host's hierarchy, goal, status, model and
latest tool. The roster is read once after each connection, on an explicit
refresh, and after coalesced `subagent.spawn_requested`, `subagent.start`,
`subagent.progress`, `subagent.tool` or `subagent.complete` events. It is never
polled, and token/reasoning events never trigger a read.

A worker tail is loaded only when tapped through
`subagent.tail({session_id, subagent_id})`. Both host and client cap it at the
latest 16 KiB and say when earlier output was cut. Cancelling or timing out a
list/tail read fails only that optional inspection request; it never closes an
otherwise usable Bot conversation. Interrupt is the only worker write in this
slice. The phone re-lists immediately before
`subagent.interrupt({session_id, subagent_id})` and compares the row's
`started_at` and `delegation_id`, so a worker that finished during confirmation
or an id replaced between snapshots is not dispatched. Current hosts generate
each `subagent_id` with a fresh UUID suffix; inside the interrupt handler they
resolve the transport-owned record once and act on that exact agent object.
The confirmation states that Hermex cannot resume the worker and that its parent
and siblings continue. An interrupt is never retried; a lost reply has an
unknown outcome. Ownership rejection asks for a reconnect, and hosts without
the methods simply show no worker control.
Steering and every wider delegation, process, spawn-tree and verification RPC
remain outside the BotClient allowlist.

Completed async delegation is durable transcript history, not user authorship.
The gateway projects its delivery row with
`display_kind: "async_delegation_complete"` plus display-only counts, duration
and delegation id. Hermex renders that typed row as a compact timeline card and
opens the untouched server report in a results sheet. It never recognizes
completion prose by prefix. The worker toolbar remains live-only and disappears
when `subagent.list` has no active rows; reopening the conversation restores
the result card from the host transcript rather than a second local history.

The three method names, exact parameters and result shapes were verified against
`tui_gateway/methods_subagents.py` and
`tests/tui_gateway/test_subagent_snapshot.py` at `HERMES_AGENT_TESTED_SHA`
`3abeca16e66cad4875f7b40beb0eb54bc4a589d5`. No live worker was interrupted for
validation. The completion display kind and metadata were verified at the same
pin in `gateway/wake.py`, `hermes_state_messages.py` and
`tui_gateway/session_history.py`.

A blocking request is whatever has parked the bot. On 0.21.2, the gateway sends
JSON-RPC server requests with string ids and methods such as `clarify`, `sudo`,
`secret` and `mcp.setup`. `BotClient` forwards those envelopes separately from
sequenced events and integer-id RPC replies. Both `session.resume` (including
`omit_messages`) and `session.events.since` restore `open_requests: [{id, method,
params}]`. Requests belong to the current runtime. Replay always includes the
array; resume omits it when empty. Once replay or a live request establishes the
modern contract, an empty or omitted resume array clears the requests.
A newer live request or cancellation cannot be overwritten by an older in-flight
snapshot. Unknown request methods remain needs-attention without an answerable
card. Request payloads and credential values are never cached.

`request.cancel {id, method, reason}` withdraws only the matching envelope.
A disconnect drops modern requests and reconnect restores the host's current
list, independently of replay-ring truncation. The phone never retries an answer.
Legacy 0.21.1 hosts retain `pending_approval` / `pending_clarify` and the
`<prefix>.request` / `<prefix>.expire` stream paths. Protocol selection follows
the received request shape, not a version-string comparison.

`BotApprovalRequest` keeps the host's own `choices`
(`once`/`session`/`always`/`deny`) and only rebuilds them when an older host omits
the field. Unknown choices never invent permanent permission. Approvals still
use `approval.respond` with the underlying queue `request_id`, which differs
from the server-request envelope id. `resolved: 0` means already resolved.
`approval.received` is deliberately never called.

`BotQuestionRequest` reads single and batch clarification, including locked
`answers` restored on reconnect. A question outranks an approval or credential
prompt. Single questions use `request.answer({id, result: {answer}})`. Batch
answers use one `clarify.lock({request_id, question_id, answer})` per outstanding
question; `remaining: []` completes the batch and `status: expired` stops sending.
Unexpected remaining questions trigger reconciliation without claiming completion.
Multi-select answers remain JSON array strings. Skip sends an empty `answer`
without `answers`, the host's cancel-all shape for a batch.

The phone uses the acknowledged `request.answer` proxy for both live and restored
requests: unlike a bare response frame, it distinguishes `ok` from `expired`.
`sudo` and `secret` send `result: {value}`; an empty value skips. Credential input
uses a `SecureField` and passes directly to dispatch without storing the value.
Legacy requests continue using `clarify.respond`, `sudo.respond` (`password`),
`secret.respond` (`value`) and `mcp.setup.respond` (`result`).

`terminal.read`, `window.read`, `preview.read`, `preview.act` and `tour` require
Desktop renderer data the phone cannot supply. Their cards report the wait and
retain Stop. `mcp.setup` alone can be declined: `request.answer` carries
`result: {value: "{\"status\":\"declined\"}"}`, which the host reads as a final no.

Nothing is sent without a tap. Generation, runtime and request id are captured
on tap and revalidated at socket dispatch. `ok` means accepted; `expired` means
already answered or withdrawn. A JSON-RPC rejection leaves the connection usable.
A lost reply has an uncertain outcome and is never automatically resent.

The request contract is verified against
[`server_requests.py`](https://github.com/NousResearch/hermes-agent/blob/3abeca16e66cad4875f7b40beb0eb54bc4a589d5/tui_gateway/server_requests.py),
[`methods_prompt.py`](https://github.com/NousResearch/hermes-agent/blob/3abeca16e66cad4875f7b40beb0eb54bc4a589d5/tui_gateway/methods_prompt.py)
and [`contracts/server_requests.py`](https://github.com/NousResearch/hermes-agent/blob/3abeca16e66cad4875f7b40beb0eb54bc4a589d5/tui_gateway/contracts/server_requests.py)
at the compatibility pin. The 0.21.1 → 0.21.2 diff does not change public
`groups.*` request/result/error shapes. Profile creation adds optional flags and
strips channel credentials by default; canonical empty chat creation and prompt
submission retain the shapes Hermex sends.

The card renders in the transcript where the work stopped, so the command sits
under the tool row that asked for it, and the composer's attention line doubles
as the way back to it. Placement is the only Bot-specific part: the surfaces,
choice buttons, decision buttons and copy are the Sessions approval and
clarification vocabulary, shared through `PendingRequestSurfaces.swift` and
`ChatDecisionButtonStyle` rather than copied; the credential field reuses the
same response field and submit button as the Sessions clarification card. Like Sessions, "Always allow"
writes a permanent host rule without a second confirmation.

Returned artifacts use the existing transcript media parser with local Markdown
file-link recognition enabled only for Bots. Assistant images, `MEDIA:` references,
`file:` links and local document links open in native Quick Look; image thumbnails
are downsampled off the main actor. Text stays synchronous while snapshots grow.
Ordinary external web links retain their normal behavior. Remote image URLs and
unknown media forms do not gain authenticated access to other hosts.

`BotArtifactContext` captures connection UUID, Profile, durable compression-tip
session ID and conversation generation. `BotClient` downloads through its existing
cookie session using `GET /api/fs/download?path=…&profile=…&session_id=…`.
Relative paths are resolved by the host's session cwd; no iOS filesystem base or
webui transport is used. Known same-origin media/download links contribute only
their path; embedded auth tokens and identity overrides are discarded. Redirects
are rejected. Each response is capped at 25 MB, including chunked responses with
no length header. Disconnect cancels downloads, stale completions are rejected,
and dismissal removes the preview's temporary file. No persistent artifact cache
is shared between conversations. Missing routes, denied files and unknown formats
leave an explicit preview failure or the native viewer's unsupported-file state.

The scoped download route and Profile/session parameters were verified in the
running host's OpenAPI schema, with source verification of
`hermes_cli/web_routers/files.py::_fs_download_path` and `fs_download`. The handler
validates session ownership even for absolute paths. An authenticated read of a
public README through the tunnel, bound to an existing session and Profile,
returned the original bytes with attachment disposition. Native format playback
still needs owner testing with returned artifacts.

Attachment selection, paste and drop stage only local copies. The composer uses
Sessions' circular + menu (File, Photos, Camera), glass card, in-card attachment
strip, collapsed pill previews and circular Send control. Picker presentation
keeps the card expanded and returns focus to the editor on dismissal.

The shared UIKit editor applies editability changes after `updateUIView` returns.
Disabling a focused UITextView synchronously inside that callback re-enters the
SwiftUI responder graph and can freeze the screen at Send. A hosted-composer test
keeps an upload pending while checking display-link frames and editor state.

Copies and records use the Bot draft key (server + connection UUID
+ Profile); navigation/relaunch never uploads them. Imports allow eight files,
25 MB each and 50 MB total. Images are converted off the main actor to JPEG
or PNG when they contain transparency, limited to 4096 pixels on the longest
edge; PDFs, text, audio and common document
formats retain their original bytes. Removal deletes the local copy after the
updated record reaches disk.

Send and Queue upload the selected files and put only acknowledged references in
that prompt. Steer/Redirect remain text-only. Images use the authenticated
`POST /api/chat/image-upload?profile=…` with `{filename, data_url}` using the
matching JPEG or PNG data URL and require
`{ok: true, path}`. This stores the image without touching `attached_images`.
The prompt carries the returned absolute path with the vision-tool instruction
used by Hermes's `_build_image_ref_message`; analysis uses the host's configured
`vision_analyze` tool. This deliberately avoids `image.attach_bytes` and its
shared next-prompt queue. It does not request native inline vision from the
conversation model.

Documents use `file.attach` with `{session_id, name, data_url}` on the captured
runtime and require `attached`, `path` and `ref_text`. The returned `@file:` token
is included verbatim. Hermes may append an expansion warning for a file outside
the session cwd; that warning does not reject the prompt. The path remains
available to agent tools. Actual document interpretation depends on the host's
tools and file format.

These upload handlers were rechecked against installed Hermes Agent 0.21.2 source
on 2026-09-14, together with prompt preprocessing and text-mode image routing.
No live upload or prompt was executed. The compatibility pin is unchanged.
Missing methods/routes fail visibly and preserve the draft; removing attachments
leaves the existing text-only path available. Cancellation and partial failure
never submit the partial set. Files already uploaded remain host-owned; there is
no verified session-scoped delete API, and the client never deletes guessed paths.
Cancel upload retains the local draft. A lost prompt acknowledgment preserves text
and local copies; recovery silently restores them to the ordinary composer.
Accepted sends clear the durable record before deleting local copies.

Bot drafts extend `ChatDraftStore` with server + connection UUID + Profile context.
After uploads finish, immediately before prompt submission, the client flushes an
unresolved marker to disk. Upload interruptions never mark a draft ambiguous. An acknowledged
send consumes the draft; explicit admission failures preserve its text. An
ambiguous outcome preserves its draft across navigation and relaunch. During
recovery, the client clears the local unresolved marker without changing text or
attachments, then reloads the host state before enabling commands. No held-message
warning, resolve/discard dialog or extra resend confirmation appears. The composer
stays editable, and the next deliberate Send/Steer/Queue/Redirect uses its ordinary
rules. A lost or unrecognized acknowledgment schedules recovery; it never causes
an automatic prompt retry. Identical text in recovered history cannot reliably
attribute a submission, so it never silently consumes the restored draft.

The composer offers Send for idle work and a Sessions-style native menu for
Steer, Queue and Redirect while busy. Selecting a mode does not submit. The
selected action is labeled beside a separate Stop button; Command-Return uses
that same action, including Redirect's consequence confirmation. A selected
busy mode stays disabled after idle until the user chooses Send. No new
animation or alternate editor is introduced.

`BotPromptMode` validates the acknowledgment for each operation. `session.steer`
accepts `status: queued` as guidance queued, not read; `session.redirect` accepts
`redirected`, or `queued` during initialization. Both return `rejected` without
consuming the draft. Send and Queue use `prompt.submit` with `queued: true`,
which prevents a raced Desktop turn from turning a fresh send into the host's
configured steer/interrupt behavior. `queued` acknowledges a follow-up;
`streaming` acknowledges immediate admission if the previous work already ended.
The handler's `voice_stopped: true` special case is reported as speech stopped,
not as a new prompt. Unknown result shapes preserve the draft and recover the
connection; they are never treated as successful sends.

All four modes share the durable submission marker. An action captures the
connection generation, runtime, turn revision and draft at the tap; confirmation
and socket dispatch reject stale actions. No automatic retry or fallback changes
one action into another. Missing methods become unavailable for that conversation
lifetime. A `4010` correction rejection preserves the draft but does not permanently
hide the operation, since an initializing agent may gain support shortly afterward.
A receipt records admission only; it is not a queue list and Stop clears it.

Contract checked against the issue's pinned hermes-agent source, without live
mutation: `tui_gateway/methods_session.py` correction handlers,
`methods_prompt.py` submit and side-agent handlers,
`session_auto_continue.py::_handle_busy_submit`, and
`session_lifecycle.py::_interrupt_session_turn`. The command catalog's `/queue`
only adds a prompt. Queue inspection/edit/remove/resume remain unavailable until
an installed host exposes a verified safe management contract. The phone does
not synthesize a queue from receipts or call generic slash commands to manage it.

Aside and background actions remain unavailable in this composer. The verified
`prompt.btw` and `prompt.background` handlers return a `task_id` and emit results
on the parent runtime as `btw.complete` and `background.complete`. They do not
append normal canonical chat history. A future slice needs explicit result
presentation and recovery behavior before offering either execution mode; neither
is a Send variant or a reason to create another canonical session.

Stop affects current conversation work, including Desktop work, queued prompts,
pending approvals and process-wide speech playback. Confirmation actions carry
connection-generation and turn-revision guards and are single-use. No Stop retry
occurs after disconnect. Acknowledgement alone does not establish completion;
current idle does. The accepted server race remains: a Stop already sent may reach
later Desktop work because the ordinary RPC has no expected-turn guard.

Roster identity is server-owned. `BotProfile` reads the Desktop title from
`ui_meta["hermes-bots"]`, then the core `display_name`, then the Profile name
(`default` reads as Hermes, as in Desktop); description follows the same order.
`BotAvatarStore` fetches `profiles.get_asset` only for rows flagged `has_avatar`,
decodes the data URL into a bounded thumbnail off the main actor, and keeps the
image in memory keyed by connection UUID plus Profile with the Desktop look
revision (`ui_meta_revisions["hermes-bots"]`). An unchanged revision skips the
fetch; a missing revision refetches on every roster load. Loading a roster drops
every other connection's images, and removing or replacing a connection purges
its entries, so equal Profile names on two hosts never share a picture. A
malformed, oversized or missing asset leaves the row on its static shape fallback.
Hermex renders Desktop's compatible classic shape and color metadata; blobatars,
pets and other Desktop renderers remain Desktop-owned. Drawn faces blink on a
sparse `BotBlinkSchedule` (shut and open entries every 3 to 5 s, phase seeded by
Profile name) so nothing repaints between blinks; only the open bot's face in the
chat title takes Desktop's 15 fps working pose, and only while its turn is live.
Reduce Motion, the shape and expression picker tiles, photos and the extensions
render one still frame; inbox rows and pinned tiles blink.
The drawn face's rest `expression` (sixteen Bloub-derived eye geometries in
`BotAvatarExpression`) is a Hermex-owned key in the same look object: Desktop's
`saveBotMeta` spreads server keys into its local copy and re-sends the whole
object, so the key survives a Desktop save, and Desktop ignores it when drawing.
Unknown values read as neutral.

`BotInbox` owns the roster for one configured server and one live subscription
that lasts while the inbox is on screen. `open()` connects, reads
`profiles.list`, then keeps the socket; the gateway advertises `change_events`
in `gateway.ready` and broadcasts `sessions.changed` whenever any served
Profile's `state.db` moves (floored at two seconds, `change_watcher.py`). Each
event coalesces into one `profiles.list` reload with at most one more queued,
spaced by one second, applied only when the reply is the newest request and the
wire still owns the inbox. Event reloads skip the avatar pass: a look change
never moves `state.db`, so nothing new would be there. Leaving the screen,
backgrounding, pull-to-refresh and Reconnect all go through `close()` then
`open()`; a dropped socket keeps the roster on screen, says live updates
stopped, and makes pin and hide inert until the next `open()`.

Roster organization is Desktop's. `pinned` and `hidden` in
`ui_meta["hermes-bots"]` are honored: pinned bots sit above the list as large
avatar tiles with the name beneath, the rest follow in server order, and hidden
bots stay out unless revealed for the session (dimmed, in place) or named by a
search. Pin, Unpin, Hide and Unhide are the row's long-press menu. Desktop's
user sections are not shown because their catalog (`bot-sections-v1`) lives in
the Desktop renderer's `localStorage` and only an opaque `sectionId` reaches the
phone; named section headers need upstream to publish the catalog on the host.
`groups` are executable group rooms, not Desktop organization sections. Their read-only viewer is described below. A
description of 24 characters or fewer reads as a role chip beside the name when
the chat has a preview; the activity label is the time today, the weekday within
the past week, otherwise month and day (`BotInboxDateLabel`). A pin or
hide write is `profiles.configure` with the whole `hermes-bots` object as
received plus one changed field, under `ui_meta_expected_revisions` set to the
row's `ui_meta_revisions["hermes-bots"]` (0 when absent), which is how the
gateway's key-wise merge keeps Desktop-only fields intact. Nothing moves until
`applied.ui_meta` is true and the roster is re-read; a conflict re-reads the
roster, shows the fresh state and a one-line notice, and never claims success.
The Profile editor is reachable from a bot row's context menu and the bot chat
toolbar. It is bound to the exact configured-server URL, Bot connection UUID and
Profile name for its whole lifetime. `profiles.describe({name})` supplies the
role, full SOUL instructions, pinned model, installed skills, configurable
toolsets and configured MCP servers. `model.options` supplies only the picker
inventory. Equal Profile names on different Bot connections never share state,
and every dispatch plus every reply revalidates the current Keychain connection.

Save is explicit. One `profiles.configure({name,...})` request carries only dirty
sections and interprets `applied` per section, so successes advance their own
baseline while failed or model-confirmation sections remain visibly unsaved. A
guarded model is resent by itself with `confirm_expensive_model` only after a
second user confirmation. A disconnect never causes an automatic retry.

Appearance writes merge the received `ui_meta["hermes-bots"]` object, changing
only title and compatible static avatar keys while retaining Desktop-owned keys.
They include `ui_meta_expected_revisions["hermes-bots"]`; a conflict leaves the
phone's edit dirty until the user explicitly reloads Desktop's latest appearance.
Avatar bytes are a separate `profiles.set_asset` write after that metadata write
has succeeded. Uploads are normalized to JPEG, capped to the host's 2 MB decoded
limit, and replacing only the asset updates the in-memory avatar even though the
look revision does not advance.

Capability pickers edit only rows returned by `profiles.describe`: disabled skill
names, the enabled toolset pin and configured MCP servers. They do not expose a
second skills marketplace, Tasks implementation or global server settings. The
existing webui Tasks, Skills and Settings screens are not linked from this editor
because there is no verified identity mapping from a direct-Hermes connection and
Profile to those separate webui contracts.

The typed BotClient exception for this editor admits `profiles.describe`, the
documented `profiles.configure` fields and avatar-only `profiles.set_asset`; it is
not a generic Profile or gateway command surface. These handler shapes were
verified against the compatibility pin `3abeca16e66cad4875f7b40beb0eb54bc4a589d5`
(`profiles.describe`, `profiles.configure`, `profiles.set_asset`) without a live
mutation. The local upstream checkout at `cd2bd160579d5240e52d01e2f735da55ff4242ef`
was also inspected for drift; the editor contract remains present.

The inbox socket reconnects on its own. A lost socket or a failed roster read
keeps the roster on screen and retries quietly with delays of 1, 2, 4, 8, 16
and then 30 seconds for as long as the inbox is open; nothing is shown and no
button is needed. Only a refusal the user must act on (sign-in, identity, an
unsupported host, a 4xx) shows the message and the Reconnect button. Leaving
the screen or backgrounding cancels the retry.

The hero face on the create and edit screens is `BotInteractiveFaceView`, after
Bloub: it blinks on the shared schedule, its eyes follow a finger dragged over
it, a tap squishes it into a surprised face for a moment, and it plays short
bits on its own. `BotFaceBit` is the repertoire (glance left, right or down,
double blink, wobble, hop, spin), each 0.5 to 0.9 s of ease-out poses that start
and end exactly at rest; the typing glance alone runs 1.6 s so one glance covers
a burst, and a cue for the bit already playing is ignored. `BotPlayfulSchedule` picks one every 4 to 9 s, seeded
by the bot's name, with a spin at most every tenth slot; a screen can also cue
a bit for what the user just did (hop for a shape, wobble for a color, glance
down while typing the name). A bit runs its own 60 fps timeline for its
duration and then hands back to the blink schedule, so nothing repaints while
the face is left alone. Only the hero moves; picker tiles and rows stay still.
Reduce Motion keeps the eyes still, plays no bits and drops the squish. The first swatch, stored as Desktop's `#ffffff`,
is adaptive: `Color.botBody` paints it white in dark appearance and black in
light, with eyes inverted to match, so the face and the swatch never vanish
into the background.

## Opening a bot from outside the app

One URL route lands on a bot conversation: `hermes-agent://bot?server=…&
connection=…&profile=…[&conversation=…]` (`BotDestination` and the parser live in
`Features/Bots/BotDeepLink.swift`, the host in the widget-shared
`HermesDeepLink`). It routes only by identity the server owns — configured server
URL, Bot connection UUID, Profile name — so equal display names, or equal Profile
names on two connections, can never resolve to each other.

`BotDeepLinkRouter` decides the outcome before anything navigates, from the Bot
Mode gate, the server registry, the destination server's Keychain connection and
the auth state: Bot Mode off, an unconfigured server, or a removed or replaced
connection drops the link and the app just opens; signed out holds it until the
next sign-in; another server activates first, and the rebuilt tree routes it. The
roster is never waited on to route. `BotsInboxView` resolves the held destination
once `open()` has settled, and a Profile the server no longer has simply leaves
the user on that inbox. Opening follows the ordinary canonical resume rules: a
link never sends a prompt and never auto-continues on its own.

`conversation` is the bot's durable canonical root when the sender knows it. It is
seeded as `BotConversation.root`, so the existing changed-root rejection refuses to
open a replacement conversation under the link's identity; the chat reports that
back and the inbox says the conversation is no longer available.

## Bot lifecycle

The inbox's `+` button and a row's context menu create, duplicate and delete
bots on the current Bot connection (#483). Hide stays the non-destructive
alternative and is offered again inside the delete confirmation.

`BotCreator` owns one create or duplicate for one connection. The Profile name
is the slug of the typed display name under the host's rule
(`[a-z0-9][a-z0-9_-]{0,63}`, never `default` or another reserved word); a name
already on the roster is refused before any write. Setup is three host writes
in order, each with its own outcome: `profiles.create` (name, optional
description, optional `model` + `provider`, `clone_from` when duplicating),
`profiles.configure` with the drawn look under `ui_meta_expected_revisions` 0,
then the canonical chat: an exact-title `session.list` first (adopt before
mint, as Desktop), and only on a confirmed absence `session.create({profile,
title: "Bot Chat", hidden, follow_profile_config})` followed by `session.title`
on the runtime id so the lazy row is persisted before any prompt; a `4022`
title collision re-reads and adopts the winner. No kickoff prompt is sent.
Try Again repeats only steps that are not done, and a step whose reply was
lost re-reads the host (`profiles.list`, `session.list`) before writing again,
so a retry never mints a second Profile or chat. A look failure is reported
and the chat step still runs; the Edit screen fixes the look later. Leaving
the sheet mid-write marks pending steps uncertain; nothing retries on its own.

Credential inheritance is one explicit switch, on by default: on sends
`share_auth: true` so the bot reads the host's `auth.json` in place (one token
pool, no forked refresh), off sends `mirror_credentials: false` so the bot
starts with no keys. Secret values never reach the phone. A create whose reply
reports neither `model_set` nor `mirrored.model_inherited` shows a one-line
note to pick a model. Duplicates clone config, skills and `SOUL.md` through
`clone_from`; the drawn look is copied, the photo asset and Desktop
organization (`pinned`, `sectionId`) are not, and the chat stays with the
original. Create-from-description (`llm.oneshot`) is not offered.

Delete is `DELETE /api/profiles/{name}` over the client's authenticated cookie
session, because the gateway has no `profiles.delete` RPC; only a 200 with
`ok` counts. The confirmation names the host and states that the Profile
folder (instructions, settings, skills, saved keys, chat history) is removed
and cannot be undone. On success the phone drops its unread mark, avatar,
drafts (`ChatDraftStore.discardBotDrafts(profile:)`) and cached history
(`BotHistoryCache.removeProfile`) for that bot, then re-reads the roster. A
refused delete leaves everything; a lost reply is reported as uncertain and
settled by the next roster read, which purges the phone's state for a bot the
host no longer lists and keeps it for one that survived. `default` is never
deletable. Once the Profile write has been dispatched the sheet locks the name,
role, model, credential switch and look: a retry finishes the remaining steps
with the values already on the host. A create that finished with leftovers (a
look that did not save, no model) stays up with the results until Done; a clean
one closes on its own.

`BotClient` admits `profiles.create`, `session.create` and `session.title` as a
second typed exception: the create shape above, exactly the canonical-chat
parameters, and nothing else. Handler shapes were verified against the
compatibility pin `3abeca16e66cad4875f7b40beb0eb54bc4a589d5`
(`tui_gateway/methods_profiles.py` `profiles.create`,
`tui_gateway/methods_session.py` `session.create` and `session.title`,
`hermes_cli/web_routers/profiles.py` `delete_profile_endpoint`,
`hermes_cli/profiles.py` name rules) without a live mutation.

Unread is device-local. `BotUnreadStore` keeps, per connection UUID and Profile,
the canonical `last_active` the user last saw, in `UserDefaults` because the
values are timestamps and never leave the phone. The first roster load seeds a
missing mark so a fresh install starts quiet; opening a chat marks it seen, and
returning marks the next roster read seen once so activity that was on screen
during the visit does not come back as unread. Removing the connection deletes
its marks with its drafts. Working and needs-attention states are not shown in
the inbox: the roster row carries no turn state for the canonical chat, and the
only live signal, `worker_session` heartbeats, describes kanban and tool
workers rather than the conversation.

Bot Mode ships behind `BotModeGate`, one app-wide `@AppStorage` bool that is off
by default and owned by the Settings "Bot Mode (beta)" row (#496), which sits
under Archived Sessions so new users notice it. Off hides the Bots row on the
session list and pops the Bots inbox if it is open; nothing else changes, and
Bot connections and drafts stay in the Keychain until it is turned on again. The
gate is not per-server because it hides screens rather than storing user data.
It is removed, together with its Settings row and `BotModeGateTests`, in the
release PR that ships Bot Mode, not before.

The Bots inbox is a utility destination of the session list, pushed like Tasks
(the detail column on iPad), so the system back button returns to Sessions and
bot chats push on from the inbox. It has no title of its own: the back button
and its search / new / connection toolbar are the whole header.

New Bot code belongs only to the main app and XCTest target, apart from the Live
Activity below. Share-extension and App Intent commands still route to webui
sessions.
Existing external entry points (session deep links, App Intents, shared imports,
webui push) replace the navigation destination, which pops an open Bots inbox.

The implementation issue links the installed contract evidence, signed-build and
test results, and remaining manual gates. Physical-phone transport, native
accessibility and integrated live behavior must be validated before declaring
the MVP complete. Simulator or isolated fixtures are not physical-phone evidence.

## Bot Live Activity

A working bot shows on the Lock Screen and Dynamic Island through the same
`AgentLiveActivityManager` and widget as a webui run; there is no second manager
(#489). `BotConversation.liveActivitySnapshot` projects the conversation into a
pure value at its state choke points, and the shared `BotLiveActivityFeed` diffs
those values into manager calls.

- **Identity.** `AgentRunActivityBot.key` is `bot:<connection UUID>:<Profile>` and
  stands in for the session id; the stream id adds the host's turn start. Equal
  Profile names on two connections never reuse an activity, a reconnect inside a
  turn re-adopts it, and the next turn gets a new one. The tap target is the #554
  bot route, so a tap validates the stored connection like any other bot link.
- **Freshness.** Bot activities request ActivityKit update tokens. For a paired
  server, `PushActivityRegistrar` forwards each token to the relay under the stored
  agent session ID (`session_key`, the resolved compression tip) and registered
  device token. The gateway's short-lived RPC `session_id` and the canonical chat
  root are different IDs; plugin progress hooks use neither of them. After registration succeeds,
  suspension leaves freshness to push; the relay sets a fifteen-minute stale date
  and the widget uses ActivityKit's stale flag. Unpaired or failed registrations
  still show "Not connected" / "Open to reconnect" on suspend. A webui run on a
  paired server takes the same handoff (#566): its attributes carry the configured
  server, it requests a token, and it registers under its webui session ID, which
  webui also gives the agent. Webui runs on unpaired servers stay local-only
  (`pushType: nil`). A compression that rotates the session ID mid-turn moves the
  plugin's progress to an ID the relay does not know, so that activity goes stale.
  Ending an orphaned webui activity, or finding one finished at cold launch,
  retires its registration so the relay stops holding that session's banners.
  There is no push-to-start.
- **Ownership.** Before every stale or end call the feed checks
  `drivenSessionID`, so an activity a webui run or another bot took over is never
  touched. Token rotation and retirement are serialized: an in-flight registration
  must be cleaned up before its replacement can register the same session. Ending,
  dismissal, and server unpairing retire registrations. Cold launch observes paired
  activities without resuming their chats; legacy/unpaired activities are removed.
  `BotLiveActivityFeed.decision` is the pure start/update/end/wait decision.
- **Privacy.** Chips are counts only (plan step, workers, tools). Reply text
  appears only behind the existing response-excerpt setting.
- **Avatar.** The app renders the bot's photo or drawn face to one PNG under
  `LiveActivityAvatars/` in the app group, named by connection UUID, and the
  widget reads it; that is why the widget target carries the app-group
  entitlement. A missing file falls back to the status dot.

The shared content state accepts both existing local fields and the relay's compact
`v`, `status`, `tool`, `tool_calls`, `started_at`, `updated_at` shape. With no reply
text, a webui activity shows `ContentState.detailChips` in place of the panel (#644):
the relay's tool count, then "Updated … ago" drawn by the system, or "Open to read the
reply" once complete. Only a real update time is shown: an app write, or a relay state
with `updated_at`; a state from an older relay shows the count alone. Local writes keep
the count the activity already shows, since only the relay counts a webui run's tools. The wire status remains a
string; unknown statuses or newer versions render a generic existing status.
Identity/title come from immutable activity attributes when a push omits them.
The app and widget share this decoder; the share and notification extensions do
not consume it. The relay contract lives in `hermex-push/relay/README.md`.

Rooms have no Live Activity.

## Bot mentions

The Bot Chat composer offers up to eight `@` completions from the inbox roster
for its own connection, excluding the open bot. The same panel also lists this
conversation's workspace files below the roster; see File references. It reuses
the slash panel's presentation and caret-local replacement behavior. Rows show a small static avatar
from the inbox's connection-scoped image cache, falling back to the bot's existing
face; opening or filtering the picker never fetches images. Once selected or
followed by whitespace, a recognized mention becomes the shared composer's
atomic chip with the bot's avatar and display name. The expanded editor and
collapsed pill use the same cached rendering; copy, cut, draft storage and send
retain the original `@tag`. Backspace removes the reference as one unit. Unknown,
ambiguous and code-span mentions stay plain text. Friendly titles and core
`display_name` values supply slug/collapsed aliases; the Profile handle remains
valid, with `default` exposed as `hermes`. Reserved friendly aliases cannot claim
`hermes`, `default`, `all`, `everyone` or `user`. Any form claimed by multiple bots
is unresolved, even if more than two bots claim it. Autocomplete falls back to an
unambiguous handle when a friendly tag collides, and omits bots with no usable
tag. Transcript filtering validates the complete trailing identification note
before hiding it; similar user-authored examples remain visible.

Mentions identify agents; they do not deliver messages. At an explicit Send,
Queue, Steer or Redirect, `BotMentions` ignores inline/fenced code and email
addresses, resolves the original draft, and appends Desktop's identification
note to the existing prompt payload. Attachment references are not scanned for
mentions. Each resolved bot appears once, in mention order. The draft stays as
typed; live and restored user bubbles hide the trailing note. The agent decides
whether to call its server-side `message_agent` tool, which owns attribution and
delivery. A session without that tool is instructed to say messaging is
unavailable. Existing admission, error, cancellation and no-retry rules apply.
The webui Sessions composer and `BotClient` method allowlist are unchanged.

Contract checked against the compatibility pin's Desktop `hermes-bots/data.ts`
(`mentionNameForms`, `botMentionTag`, `resolveRosterMentions`) and `plugin.tsx`
mention middleware. No live prompt or relay mutation was used for validation.

Cross-connection messaging remains an upstream gap. The phone never calls
`bot_relay.roster.sync`, `outbox.drain`, `deliver` or `reply`: taking over Desktop's
roster or draining its envelopes from a suspendable phone could strand work.
A manually typed `@name@connection` can be interpreted by `message_agent` when
Desktop has synced the peer roster within ten minutes, and delivery requires
that Desktop to remain running. The phone cannot autocomplete remote bots
because there is no read-only remote-roster RPC. Real phone support needs that
RPC and a relay owner independent of a Desktop renderer.

## File references

The `@` panel is one panel with two groups: the roster above (see Bot mentions),
then this conversation's workspace files. With no roster the panel is files
alone; with no file rows (a failed or empty lookup) it is the roster alone. One
gesture, no mode rules: a mention-shaped word (`@res`) can offer both, and a
path-shaped one (`@src/Ch`) can only match files, because bot tags contain no
slash. `BotAtPanelSection` owns that ordering, and a lookup still in flight
shows the Files group with no rows yet so the first answer can appear.

File rows come from the direct connection's `complete.path` (#552; the epic's
exclusion was reversed 2026-09-17). The client sends `{word, session_id,
profile}`: `word` is the path being typed — a bare `@` sends `.`, because the
host answers an empty word with no items — and `session_id` is the live runtime,
so rows resolve against the session's working directory (`session.cwd.set`). The
reply's `items` rows are plain relative paths or the host's `@file:`/`@folder:`
directive spellings; directories end in `/` and carry `meta: "dir"`. Rows a
`@path` reference cannot carry — directives, whitespace, `..`, absolute paths —
are dropped. The host ranks and caps its own rows (30), so the phone neither
relists nor rescores them.

Picking a file inserts `@path` plus the trailing space and draws the same chip
the Sessions composer draws; picking a folder inserts `@path/` and leaves the
panel open on its contents. A picked path is remembered for the conversation's
lifetime so its chip draws, and is forgotten when the workspace moves: a path is
only a file inside the workspace it was found in. A failed lookup hides the
Files group and never blocks typing; a reply that lands after a newer query is
dropped by the panel's generation guard, the same one the Sessions panel runs
under.

`BotClient` admits `complete.path` as a fourth typed exception: exactly `word`,
`session_id` and `profile`, one bare word with no whitespace and both ids
non-empty. Cancelling a completion drops its reply without dropping the
conversation, because a completion has no outcome to recover. Group rooms are
untouched: `BotRoomComposerView` keeps its members-only mention panel and never
gets the Files group.

Contract verified read-only against the live host on 2026-09-18 (the host
reported 0.21.3; `HERMES_AGENT_TESTED_SHA` is 0.21.2) with authenticated
`complete.path` calls: `word: ""` answers `{items: []}`, `word: "."` lists the
root, directories carry a trailing `/` and `meta: "dir"`, and the listing caps
at 30. The shape matches the pin's
`tui_gateway/methods_complete.py::complete.path`; the listing root resolves as
`cwd` → live session cwd → profile-configured cwd → launch cwd. No resume,
prompt or mutation was executed.

## Slash suggestions

Typing `/` at the start of a Bot Chat draft opens the slash panel with this
connection's **skills**. Commands are deliberately absent: the gateway runs those
only through `slash.exec` and `command.dispatch`'s quick/plugin/registry stages,
which Bot Mode does not expose, so a command row would insert text nothing runs.
Model, effort and workspace already have native controls (Chat controls above).

`commands.catalog` (no parameters) is read once per conversation, after connecting,
driven by the composer. `BotSlashCatalog` reads the `skills` keys for which entries
are skills and the `pairs` rows for their descriptions, and **drops any skill key
that also appears in `canon` or `commands`**: those are registry, quick or plugin
commands, `command.dispatch` resolves them ahead of skills, and a `quick_commands`
entry of type `exec` runs a shell command on the host. A failed read is silent and
retried on the next connect; the panel simply does not open and typing and sending
never wait on it. A reply for a conversation that has moved on is dropped. Nothing
is shared across servers or connections: `BotConversation` is one
server/connection/Profile lifetime.

`BotSlashTrigger` narrows `ComposerSlashTrigger` to a `/` that opens the draft and
ends at its first space — past that the user is typing the skill's argument. The
panel is closed for Steer and Redirect, which never expand an invocation. A `@`
mention wins over a `/`, so the two panels never stack. Rows reuse the slash
panel's dense glass presentation and `SlashSkillFormatter.matching` ranking;
choosing one inserts the skill's **slug**, which is what `ComposerChipCatalog` is
keyed by, so the shared composer draws it as an atomic chip through
`ComposerChipTextView`, exactly as Sessions does. The send path resolves the slug
back to the host's own key, so a key like `/Weekly_Report` completes as
`/weekly-report` and still dispatches under its real name.

`prompt.submit` never interprets a leading `/`. So at Send or Queue, a draft that
opens with a catalog skill is expanded first: `command.dispatch {name, arg,
session_id}` returns `{type: "skill", message, name, display}`, and `message` is
what gets submitted. Only a catalog skill name is ever dispatched, and only a
`skill` reply is used — anything else, or a failed dispatch, sends nothing and
leaves the draft with an error. The catalog is re-read immediately before
dispatching, because the cached one is a connect-time snapshot and a command added
to the host since then would shadow the skill; the read also refreshes the panel.
The last microseconds of that race cannot be closed from the phone — the gateway
has no skill-only dispatch. Expansion happens before any durable marker, so a
failure cannot strand a submission. The transcript still shows the typed line,
because the host projects the invocation back over the stored message
(`display_kind: "skill_invocation"`).

`BotClient` allowlists `commands.catalog` (no parameters) and `command.dispatch`
(exactly `name`, `arg`, `session_id`; a bare name with no slash or whitespace) as
its third typed exception. `slash.exec` stays unsupported.

Group rooms are out of scope: `BotRoomComposerView` is a separate composer and
does not get the panel.

Contract checked against the `HERMES_AGENT_TESTED_SHA` pin (`3abeca16`, 0.21.2):
`tui_gateway/methods_tools.py` (`commands.catalog`, `command.dispatch`,
`_dispatch_quick`/`_dispatch_skill`), `tui_gateway/methods_complete.py`
(`complete.slash`, a per-keystroke read the catalog replaces) and
`tui_gateway/session_history.py` (`_skill_scaffold_projection`). Neither read is
Profile-scoped upstream while dispatch is, so the list belongs to the connection,
not the Profile. No live mutation was used for validation.

## Chat controls

The Bot composer reuses Sessions' model/effort menu, model sheet, workspace picker
and context indicator. `BotChatControls` owns their connection/Profile/runtime
context independently of webui configuration. The ready composer stays quiet;
the expanded row contains the model/effort, workspace, fast mode and the Sessions context ring.
Session controls appear in the navigation bar only when the host reports them.

`model.options` supplies provider groups, model choices and the active agent's
model/provider. Do not take the active selection from `session.info.model`: that
field deliberately projects a queued next-turn choice. `config.set` is allowlisted
for model, reasoning and fast. Model requires a runtime and an explicit `--session` flag plus
`scope: session`. The value is `<model> --provider <provider> --session`; identifiers
containing flag tokens or whitespace are rejected before dispatch because the
host uses a whitespace parser, not shell quoting. The model reply's `key`, `value`, `scope`, `confirm_required`, `confirm_message`
and `deferred` determine whether to request confirmation, show a next-turn pick,
or re-read the active model. No pending pick gets an active checkmark. Reads are
coalesced on session-info, turn-boundary and session-control events, never polled.

Reasoning and fast mode use `config.set` with `{profile, session_id, scope:
"session", key, value}`. Reasoning sends only `none`, `minimal`, `low`, `medium`,
`high`, `xhigh`, `max` or `ultra` (never the host's display commands). Fast sends
`fast` or `normal`, never a retry-sensitive toggle. Matching `key`/`value` replies
acknowledge the selection; rejections preserve the old value. Both choices are
bound to the captured runtime and active model, and are invalidated on disconnect.

**Accepted host limitation (#479):** in the compatibility pin's
`tui_gateway/methods_config_set.py`, `_set_reasoning` and `_set_fast` fall back to
writing Profile config if the runtime disappears, even with `scope: session`.
The maintainer explicitly accepted this race to enable parity with Cadu. A client
preflight cannot eliminate it; the host must eventually reject stale runtimes.
This is not authorization to deliberately write Profile defaults.

`session.cwd.set` accepts `{session_id, profile, cwd}` while idle and returns
`cwd`; the displayed workspace changes only after acknowledgment. It can be
changed back through the same picker. `session.control.read` returns `control`
with optional `goal`, `loop` and `heartbeat` records. The phone exposes only
pause/resume for known active/paused states, confirms their consequences, and
uses `session.control`'s returned snapshot. Unknown states are read-only;
unsupported/denied methods become unavailable. No raw configuration editor,
control creation, clearing, gate execution or general slash runner is exposed.

The resume snapshot's `info.usage` maps `context_used`/`context_max` and cumulative
`input`/`output` into the shared context presentation. Missing current-context
fields show the same disabled “–” ring as Sessions; cumulative input never substitutes for context used.
No cost, compression threshold or usage breakdown is invented. This slice does
not call `session.context_breakdown`, which can rebuild the host's prompt merely
to inspect it.

The contract was checked against the source named by `HERMES_AGENT_TESTED_SHA`:
`methods_complete.py::model.options`, `inventory.py::build_model_options_payload`,
`server.py::_session_info`, `methods_config_set.py::_set_model`,
`model_switch.py::parse_model_switch_args`, `methods_session.py::session.cwd.set`
and `methods_session_control.py::session.control.read/control`. No live host
mutation was used. Socket dispatch, read completion and confirmations all validate
the captured context; disconnect invalidates them and never retries a write.
Older snapshots cannot overwrite an acknowledged workspace change. Rejections
keep the previous value and preserve the host's error text.

## Recent chat entry

`BotHistoryCache.recent` keeps value snapshots for at most 12 recently visited
bot/room chats within an 8 MiB estimated payload budget. It is memory-only and
separate from the lossy disk search index. Bot snapshots retain the last 500
messages (including long text and display metadata), settled tool/reasoning rows,
and visible inflight text frozen as history. Room snapshots retain system events
as well as messages, their replay cursor and earlier boundary. Thumbnails may
still load separately.

New views read the projection synchronously before starting network recovery.
Only a fresh server response grants runtime identity, working state, approvals or
send permissions. Refresh replaces bot history and continues room delta replay.
Deep links must match the cached canonical root; a fresh lookup of a replacement
Bot Chat discards the old preview. Already-open chats keep established read-only
history on identity loss. Warm room search still anchors to its selected sequence.

The store uses configured server hash + connection UUID + bot/room identity.
Each recovery claims a writer token, so a superseded screen cannot overwrite a
newer projection. Offline-cache clearing, connection/server removal, deletion and
authoritative roster pruning invalidate the corresponding entries and writers.
The small lock only protects in-memory value copies; disk work stays on the
history actor. No sockets, credentials, pending actions or live permissions are
cached. App termination discards all recent projections.

## Local search

The top-right search button opens a sheet with a focused search field and an
All / Bots / Messages filter. Bot names use the current roster, including hidden
bots when a query matches. Message search is entirely local: it searches saved
user/assistant text from full, identity-validated Bot snapshots and user/member
messages from group room pages this iPhone has loaded. It never uses webui history or calls a server search/resume endpoint.
The coverage label is “Messages saved on this iPhone.” There is no initial server
crawl, attachment indexing, or live-token indexing.

`BotHistoryCache` serializes disk access and matching off the main actor. It keeps
one snapshot per configured server hash + connection UUID + Profile, including
canonical root and compression tip, but no runtime identifier. Refresh replaces
the snapshot, so undo/compression cannot accumulate obsolete search rows. The
cache is disposable, under Library/Caches with file protection: 30-day lifetime,
100 snapshots, 8 MB encoded globally, and up to the latest 500 projected messages
per bot or room. Messages over 16 KB are omitted. Search returns at most 100 matches and
asks the user to refine at the cap. Unknown roles, tool output, credentials from
prompt cards, inflight text, and drafts are not indexed.

Room rows use configured server hash + connection UUID + room ID, never the room
name or member Profile. Completed replay windows append by `seq`; overlaps do
not replace existing messages. Pages in each window commit together so fetching
earlier history preserves the newer cached window. Only `message.user` and `message.member` text, sender identity and time
are saved. The separate cursor includes invisible events. Cached coverage stays
contiguous; eviction advances its earlier boundary. Bot and room results share
the 100-hit limit and global storage budget. A room hit shows its room and sender
and opens the normal room at the saved sequence, revalidating the connection and
room after search dismisses. When the room list is unavailable (including cold
start offline), saved room names and sender text remain searchable. Selecting a
hit admits only that cached identity for navigation; runtime permissions and
members still come from fresh state. A successful room list always wins over the
cached fallback, including if it refreshes while search is dismissing. If the cache was evicted, the reader fetches that
sequence again. Expiry/disband revokes late writes and removes the room rows;
a complete active room list also removes cached rooms that have disappeared.

A Bot message result holds the selected immutable snapshot and opens a read-only
text reader at its local message ID. Those IDs belong to the saved projection;
they never become RPC targets. A bot result deliberately opens its normal chat
only after the sheet dismisses and the connection/Profile selection is validated
again. Cache results and reader selections are discarded on connection change;
backgrounding cancels search. New queries cannot publish old search results.
When the roster is unavailable, cached message results use the saved bot name;
a successful roster refresh excludes messages from removed bots.

Clear Offline Cache clears this server's Bot cache too. Removing a Bot connection,
replacing its endpoint/account, signing out, or removing its configured server
also removes its saved messages. Removal revokes pending writes for the old
connection; clearing rejects writes captured before the clear and permits future
snapshots. Identical Profile names on different connections never share history.

## Group rooms

The gateway owns room execution. iOS may poll reads while a room is visible;
it never orchestrates member turns, retries work, or opens the hidden
`Group: <room_id>` sessions. There are no room push events at the tested pin.

On inbox open and pull to refresh, `groups.capabilities` gates room rows: `driver`
must be true and `methods` must include `groups.list`,
`groups.state`, and `groups.log`. Missing capabilities hide rooms, including name
search. Group rooms and unpinned bots share one newest-first list, using room
updated time and bot last activity. Undated chats sort last; ties use stable chat
identity. Revealed hidden bots join that order, with the reveal control at the
bottom. Pinned bot tiles remain above the list.
The top-right + menu offers New Bot and New Group Chat; group creation is disabled
when the host lacks its capability. `groups.list` pages all active
rooms; disbanded entries are excluded. Identity is configured server URL + Bot
connection UUID + `room_id`; names and member Profiles are never room keys.
Avatars resolve against that connection’s roster, with a placeholder for unknown
members. Search matches room names and previously loaded room messages through the local cache above.

`BotRoomReader` owns an independent socket and in-memory `BotRoomLog`. Opening
restores cached messages first, then reads state and drains pages from the saved
cursor until `has_more` is false. Without cache it starts at
`max(0, latest_seq - 200)` (or the selected search sequence). Each completed replay window
updates the best-effort cache; cache read/write failures never stop live reading. Load earlier reads the preceding 200-event window. Duplicate
`seq` values are ignored, events sort by sequence, and invisible/unknown kinds
still advance the cursor. Authority epochs never reset the cursor. An authority
change triggers a state read; a foreign gateway shows “Managed by another Hermes”.

While visible and foregrounded, state reads run every two seconds when working
or blocked and every ten seconds when idle. Log reads happen only after sequence
advancement. Unchanged polls do not assign the transcript. Backgrounding, closing,
and socket loss stop polling and invalidate late replies. Reconnect closes the
old transport before opening and re-reading state/history. Closing drops the in-memory log; bounded cached messages remain for reopening.

The transcript renders `message.user` and `message.member` with the existing
Bot markdown renderer; member messages include their sender and roster avatar.
`turn.failed`, `turn.cancelled`, `room.stop_requested`, and `room.renamed` are
centered system lines. `room.activity`, `turn.settled`, `turn.deferred`,
`authority.*`, and all unknown kinds remain invisible. Driver status reports
room-wide working/blocked state, never an inferred active member. Pending actions
use the participant controls below; unknown kinds show Desktop attention. Room profiles link to existing bot profiles and expose the lifecycle controls below.

The socket allowlist admits four room reads, four participant commands and three lifecycle commands with typed parameter checks.
Room RPC errors preserve `data.reason`: `room_history_expired` or code 4114 removes
the room with a toast; 4123 asks for a gateway restart on the Mac. No replica, peer, promotion, or demotion method is permitted.

Contract: `tui_gateway/methods_groups.py` and `gateway/hosted_rooms.py` at
`HERMES_AGENT_TESTED_SHA`; read-only tunnel checks on 2026-09-16 captured
capabilities, the “Comms” list/state, and its empty log on 0.21.2. The checked-in
fixture replaces the installation identity. Synthetic pages cover non-empty replay.

### Room participation

The text-only composer uses room member handles and display names for mention
completion, plus `all` and `everyone`. Text is sent as typed, without the Bot Chat
identification annotation. Each explicit send mints both an `event_id` and a fresh
`thread_id`: sharing a thread would supersede work rather than queue it.
`groups.send` acknowledges a durable append and admission, not a bot response.
The result inserts one bubble by sequence without advancing the log read cursor;
polling cannot duplicate that bubble or skip earlier events. The server may trim
surrounding whitespace in its acknowledged text.

A lost reply preserves the draft and reports an unknown outcome. Reconnect only
reads state/history. Only the explicit Retry send button reuses the original id,
thread and text; ordinary Send stays disabled while that outcome is unresolved.
Pending commands are invalidated before a room closes or backgrounds. Drafts and
uncertain commands stay with that room reader in memory, never another connection.

Stop targets every bot in the room without confirmation. Its `cancelled` receipt
is informational; the status stays Stopping until a subsequent state read reports
no stopping tasks. Queued/running counts govern whether Stop can be tapped.

Approvals use the existing request card with only `once` and `deny`. Dispatch
revalidates the room, socket owner, authority epoch and exact member/task/generation/
request tuple. Retry targets the pending task. Codes 5119 and 5118 re-read state;
an addressed approval tuple stays inert, including across reconnect after an
unknown outcome. Commands are never automatically resent. A retry becomes
available for a later stalled attempt only after the previous pending action
has disappeared. Unknown or incomplete pending kinds show Desktop attention.

Foreign authority hides the composer. Missing authority or unadvertised methods
cannot dispatch participant commands. No peer or authority administration is exposed. These helpers belong only to the app target; share
extension, Live Activities and App Intents do not participate in rooms.

### Room lifecycle

New Group Chat selects two to six bots from the current connection, including
hidden bots when the filter names them, then asks for a name of up to 200 Unicode
scalars (the server's character count). Members are frozen after creation.
`groups.create` sends a device UUID `room_id`, `name`, and `members` containing
`member_id`, `profile`, `handle`, and optional roster `display_name`; it never
sends `target`. At the compatibility pin, `profiles.list` has no separate handle,
so all three identifiers use the Profile name, including `default`.

The first dispatched attempt freezes its ID and payload. Try Again explicitly
reuses both, even after a lost reply; it cannot create a second room. Error 4110
re-reads the active list; a room with the attempted ID, same authority and frozen
member identities completes creation even if another client renamed it after a
lost reply. Other conflicts stay errors. Code 4123 asks for a gateway restart on the Mac.
Closing or backgrounding the sheet invalidates late replies. Success opens the
acknowledged room under the same configured server and connection identity.

Inline rename sends `groups.rename {room_id, event_id, name}` with a new event
UUID. The profile, pill and inbox update after acknowledgment; a concurrent poll
cannot publish the pending name. At the pin the result is `{room}` with the event
nested in `room.event`; the log renders `room.renamed` once by sequence.

Disband permanently removes the room and history from every device and stops its
bots. Its confirmation states those consequences. The control waits while Stop
is finishing; a 5114 rejection refreshes state. `groups.disband {room_id}` succeeds
only on a matching tombstone. A lost reply reads the complete active list, never
resends disband; a failed read keeps the outcome unknown until Reconnect.
A tombstoned room ID is permanently reserved and must never be reused.
Foreign-authority rooms hide rename/disband; absent capabilities disable writes.
The room and profile share state but claim separate view ownership so navigation
cannot let an old screen close the new screen's socket. Lifecycle helpers belong
only to the app target; the share extension and Live Activity do not manage rooms.

## Activity presentation

Bot and room composers share one action pill for requests, errors, reconnect,
and retry. In rooms, command errors and uncertain-send recovery take precedence
over a blocked member's request; its inline action card remains available.
Routine Working/Connecting banners are omitted. Room
requests link to their cards; Stop and uncertain-send guards remain in effect.

Single-bot transcripts reuse the Sessions "Working for" row only while connected
and confirmed running, with a valid server `inflight.started_at` or
`turn_started_at`. Missing or future timestamps never fall back to a phone clock.
New-turn events clear the previous timer until their snapshot arrives; reconnect
restores the server's original start. Waiting, stopping and idle hide the row.
This is elapsed wall time since the server started the turn, not active CPU time.
Rooms have no elapsed row: the tested `groups.state` contract exposes aggregate
activity but no current-work start timestamp.

## Push provisioning

The Hermes connection screen is not behind the Bot Mode gate (#557). Pairing for
push needs that login, and push serves the server's webui sessions too, so
`ServerDetailView` links it for every configured server while the Bots inbox
stays gated. Its copy says "Hermes connection" and why a webui-only user would
add one.

Notification controls live in Settings → Interaction → Notifications, collapsed by
default. That group owns push setup/disable, the per-device reply/subagent/preview
choices for the selected server, and the existing global local-alert and Live
Activity excerpt controls. The Hermes connection screen only edits the host login.
Push preferences live with the pairing in server-scoped Keychain storage; older
pairings adopt the relay defaults (replies and previews on, subagents muted).
Registration refreshes and preference writes run in order so a launch or token
rotation cannot overwrite an accepted choice. Failed saves keep the confirmed
values visible. A durable pending-sync marker is saved before remote writes; if
confirmation or rollback fails, Settings hides the unconfirmed switches and offers
retry. Returning to Settings or refreshing registration reconciles the saved choices
before clearing that marker. Changing preferences does not retire an existing Live Activity.

Turning notifications on is one confirmed action per server, driven by
`HermexPushProvisioner` over `BotDashboardClient` (the host's REST surface, no
gateway socket). It reads `GET /api/plugins/hermex-push/pairing` first, and only that
route's own answers decide what the host needs: 200 means the relay is set and the plugin
loaded, so it is paired as it stands, with nothing installed and no restart interrupting
work; 409 means a loaded plugin with nowhere to send, which needs the address alone, since
the plugin re-reads it; 404 means the plugin is missing, which needs the full sequence.
Anything else — a timeout, a server error, keys this build cannot read — is reported as it
is, because reconfiguring on those would replace a self-hosted relay and restart a gateway
over a failure that had nothing to do with setup. The full sequence runs
in the order the host needs: `PUT /api/env` sets
`HERMEX_PUSH_RELAY_URL` at the root so every Profile inherits it, `POST
/api/dashboard/agent-plugins/install` and `…/hermex-push/enable` install the
plugin, `POST /api/gateway/restart` loads it, and `GET
/api/plugins/hermex-push/pairing` returns `{relay_url, install_key, preview_key,
platform, payload_version}`. Verified against a live 0.21.3 host on 2026-09-19:
install takes `{identifier, force, enable, catalog_name, ref}` with no Profile
parameter, enable and disable are path-only, and only `PUT /api/env` and the
restart accept one. The install identifier is
`https://github.com/uzairansaruzi/hermex-push.git/plugin`, sent with `force` true so a
second run — re-enabling after a disable, or repairing a plugin too old for this build —
reinstalls instead of refusing. Reinstalling cannot unpair a phone: the plugin keeps its
key pair in `plugin-data`. The revision is whatever the repository resolves to; pinning a
`ref` is an open owner decision.

The restart drops the route, so the pairing read retries a missing route, a 409
from an unread relay address and a refused connection on a fixed schedule before
the step fails. A failure names its step and leaves nothing half-paired: the keys
are wiped, and the host hands back the same pair on the next attempt, because the
plugin keeps them in `plugin-data` rather than its install directory.

The relay address is not a field on the phone. A host that already names its own relay
keeps it — that is what the probe protects — and a host that has never been set up gets
`HermexPushPlugin.defaultRelayURL`. Self-hosting stays a server-side setting.

A failed step says what the host answered (the status code, a timeout, a rejected
sign-in) in provisioning's own words; `BotFailure`'s chat copy never reaches this screen.
`BotDashboardClient` waits 120 seconds per request, because installing clones a
repository on the host and a restart takes the gateway down and back up.

`HermexPushPlugin` owns only what the plugin itself defines: its name, its install
identifier, the env var it reads, and a strict decode of the pairing route — a 64-hex
install key, a preview key that is base64 of 32 bytes, and an https relay (plain http
only to loopback). Strict rather than tolerant on purpose: a key the relay would refuse
would pair a phone that could never receive a push. The keys themselves are a
`PushPairing`, and storing them, minting a device token and registering it are
`PushRegistrar`'s job (`HermesMobile/Push/`, #558); provisioning holds no copy and
reaches that side only through `PushPairingEnabling`.

A confirmed run is never cancelled when the screen closes — the host has already been
asked to change — so it can outlive a removal. It commits nothing without re-reading the
saved connection first: if the connection or its server is gone, the keys are not written
and a device registered seconds earlier is dropped again, so teardown stays final.

Every way out removes this phone at the relay and wipes the keys.
`HermexPushProvisioner.disable()` stops the host sending first, then calls
`PushRegistrar.disable`, so a failure at either end changes nothing the user has to
unpick. `PushRegistrar.forget` is the teardown that cannot fail — the keys go whether or
not the relay could be told — and connection removal, a changed account identity,
sign-out and server removal all run it.

## Push previews and taps

`HermesNotificationService` is the fourth target (#559). A relay banner arrives
content-free ("Hermex / New activity") with `mutable-content`, and outside `aps` carries
`v`, `kind`, `event_id`, `install_hash`, `session_id`, `source`, `is_subagent` and
`sealed`. The extension finds the pairing whose `sha256(install_key)` equals
`install_hash`, opens `sealed` (base64 of `nonce(12) || AES-256-GCM ciphertext ||
tag(16)`, AAD `hermex-preview-v1:<that hash>`) and rewrites title, subtitle and body. On
any failure — a null `sealed`, no pairing, a wrong key, a tampered blob, running out of
time — the banner stays content-free, with only `New activity` localized. Format and test
vector: `hermex-push` `plugin/hermex_push_tests/fixtures/sealed_preview.json`.

Target membership is deliberate. The extension compiles `NotificationService.swift` and
`HermesMobile/Push/PushPreview.swift` and bundles `Localizable.xcstrings`; that shared
file imports only Foundation, CryptoKit, Security and UserNotifications, and reads the
push access group with `SecItemCopyMatching` so KeychainAccess is not linked. Its
entitlement is the push Keychain group alone: no app group, no networking, no SwiftData.
`PushPreviewKeys` decodes the same Keychain JSON `KeychainPushPairingStore` writes, so a
rename of `installKey` or `previewKey` in `PushPairing` breaks previews.

The Profile exists only inside the ciphertext, so the extension writes it back to
`userInfo["hermex_profile"]`. `PushAppDelegate` is the notification-center delegate: a
tap becomes `PushNotificationRouter.botDestination` — `source == "bot"`, the pairing
picks the server, that server's Bot connection supplies the UUID — and rides the one bot
deep link (#554) through `AppIntentRouter`. No conversation is passed: `session_id` is
the run's live session, not the bot's durable root. A tap only navigates; an approval is
never answered from a banner. Anything unroutable just opens the app. Webui taps use the install's configured server
and `session_id`, independently of Bot Mode and preview decryption. After switching to
that server (and signing in if needed), a live session lookup opens the conversation;
a missing session leaves its session list without an error. It never searches another
server or uses a stale cached session. A paired server suppresses local completion
notifications from both chat and cold-launch Live Activity reconciliation; disabling
push restores the existing global local-notification preference. Webui Live Activities
on a paired server hand off to the relay like a bot's (see Bot Live Activity). Grouping (`thread-id`), the self-rewriting banner (`apns-collapse-id`) and "no
banner while a Live Activity carries the session" are relay policy (`relay/src/policy.ts`),
not app code.
