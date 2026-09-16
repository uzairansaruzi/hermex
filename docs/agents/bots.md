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
and the connection screen stores it on the `BotConnection` record. A release
other than `BotConnection.testedHermesVersion` shows a one-line "Untested Hermes
version" note and keeps the screen up after a successful connect so the note is
seen; a missing `version` shows nothing. Login is never blocked on it: each RPC
validates the contract just in time. Advancing the pin is described in AGENTS.md
(Working with the server); update the file and the constant together.

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

A blocking request is whatever has parked the bot. Approvals and questions come
from the resume snapshot's `pending_approval` and `pending_clarify`, which ride
both the full and the `omit_messages` read, so an answer given in Desktop clears
the card on the next snapshot and nothing polls. `BotApprovalRequest` keeps the
host's own `choices` (`once`/`session`/`always`/`deny`, already narrowed by
smart-approval and permanent-allow policy) and rebuilds them the way the gateway
would when an older host omits them; `BotQuestionRequest` reads the single
(`question`/`choices`/`multi_select`) and batch (`questions` + locked `answers`)
clarify shapes, keeping each choice's wire label so the host strips its own
"(Recommended)" suffix rather than the phone reconstructing it. A clarify
outranks an approval: approvals resolve inside a tool batch, a clarify blocks the
turn. A pending key the phone cannot address still reads as needing attention,
without a card.

Answering is `approval.respond`, `clarify.respond`, `sudo.respond`,
`secret.respond` and `mcp.setup.respond`. `BotClient` explicitly allowlists
these response methods. Nothing is ever sent without a tap. Generation, runtime
and request id are captured on tap and revalidated at the socket write, so a
stale card fails closed. Three outcomes are distinguished: `resolved > 0` or
`status: ok` is accepted; `resolved: 0` or `status: expired` means the host had
nothing left to resolve, which is an action failure that leaves the card inert;
a lost socket is a delivery failure whose outcome is unknown, warns, and is never
resent, though a deliberate second answer after reconnect stays the user's call.
A JSON-RPC error arrives over a live socket, so it reports the answer failed
without tearing the connection down. `approval.received` only acknowledges
delivery and is deliberately never called. Batch answers send one
`clarify.respond` per question id and stop at the first `expired`; multi-select
answers go as a JSON array string, which is what the host parses. A batch is
all-or-none: the host locks every answer it is handed and reads an empty one as
a skip, so a partial send would silently skip the questions the user never
touched. `skipQuestion` is the deliberate none. A present `choices` array is the
host speaking and nothing is added to it — if a future host renames the lot so
none of it parses, only Deny is offered, because rebuilding there would invent
an "Always allow" the host never sanctioned.

`sudo`, `secret`, `terminal.read`, `window.read`, `mcp.setup`, `preview.read`,
`preview.act` and `tour` never reach a snapshot, so `BotStreamRequest` tracks
them from `<prefix>.request` to `<prefix>.expire` and they stop the app claiming
the bot is working. Because the stream is their only record, a sequence gap, a
`message.start`, an idle snapshot or a lost socket drops the card rather than
showing a stale one. `.expire` fires only on timeout, so an answered one is
retired at dispatch instead. Replay does restore one while the ring still holds
it: `reconcileReplay` routes missed events through `applyStreamRequest` before
the activity reducer, so backgrounding past a credential prompt and returning
finds it still there rather than a blocked bot that looks idle.

They split two ways. `sudo` and `secret` block on a value only the person has,
and the phone sends it: `sudo.respond` and `secret.respond` take a `request_id`
from any connected client, and the host's own terminal UI answers over the same
methods. `BotCredentialRequest` carries the kind's `valueKey` (`password` vs
`value`) because each handler reads one name and a mismatch answers empty. The
field is a `SecureField`, the value is passed straight to the dispatch and held
by no layer of the phone, and Skip sends the empty string the host documents as
a decline — the sudo command fails, the secret tool records a skip, and the bot
is released immediately instead of parking until the deadline.

The other six are `BotDesktopTaskRequest`: the answer is data Hermes Desktop's
own renderer holds — its terminal scrollback, the window beneath it, its preview
pane — so no client without that window can produce one, on a phone or anywhere
else. Nobody types an answer at the Mac either. Each has a host deadline (30s for
the reads, 45s for preview and tour, ten minutes for `mcp.setup`) after which the
tool takes an empty answer and the bot carries on, so the card reports the wait
and keeps Stop rather than sending the user to a desk.

`mcp.setup` is the one kind a person really does walk through in Desktop, and
the only one with anything to decline. `mayDecline` gates it separately from
`mayAnswer` — declining is not answering, since the setup still only happens in
Desktop — and sends `mcp.setup.respond` with `{"status": "declined"}`, which the
tool reads as a final no and is told never to re-ask. That turns the longest
wait in the set into one tap, and it is the reason the composer's status line
says "handling this" only where there is genuinely nothing to do.

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
25 MB each and 50 MB total. Images are converted off the main actor to JPEG,
limited to 4096 pixels on the longest edge; PDFs, text, audio and common document
formats retain their original bytes. Removal deletes the local copy after the
updated record reaches disk.

Send and Queue upload the selected files and put only acknowledged references in
that prompt. Steer/Redirect remain text-only. Images use the authenticated
`POST /api/chat/image-upload?profile=…` with `{filename, data_url}` and require
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
`groups` are executable group rooms, not sections, and stay untouched. A
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
verified against the compatibility pin `ee35a4624fa22237a90426f5e21d8b4f2ce3a49b`
(`profiles.describe`, `profiles.configure`, `profiles.set_asset`) without a live
mutation. The local upstream checkout at `cd2bd160579d5240e52d01e2f735da55ff4242ef`
was also inspected for drift; the editor contract remains present.

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
by default and owned by the Settings "Bot Mode (beta)" row (#496). Off hides the
Sessions/Bots switch, the Bots inbox and the per-server Bot connection row;
nothing else changes, and Bot connections and drafts stay in the Keychain until
it is turned on again. The gate is not per-server because it hides screens
rather than storing user data. It is removed, together with its Settings row
and `BotModeGateTests`, in the release PR that ships Bot Mode, not before.

New Bot code belongs only to the main app and XCTest target. Share-extension,
App Intent, deep-link and Live Activity commands still route to webui sessions.
The Sessions/Bots switch returns to Sessions for existing external entry points.

The implementation issue links the installed contract evidence, signed-build and
test results, and remaining manual gates. Physical-phone transport, native
accessibility and integrated live behavior must be validated before declaring
the MVP complete. Simulator or isolated fixtures are not physical-phone evidence.

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

## Local search

The top-right search button opens a sheet with a focused search field and an
All / Bots / Messages filter. Bot names use the current roster, including hidden
bots when a query matches. Message search is entirely local: it searches saved
user/assistant text from full, identity-validated Bot snapshots this iPhone has
loaded. It never uses webui history or calls a server search/resume endpoint.
The coverage label is “Messages saved on this iPhone.” There is no initial server
crawl, attachment indexing, or live-token indexing.

`BotHistoryCache` serializes disk access and matching off the main actor. It keeps
one snapshot per configured server hash + connection UUID + Profile, including
canonical root and compression tip, but no runtime identifier. Refresh replaces
the snapshot, so undo/compression cannot accumulate obsolete search rows. The
cache is disposable, under Library/Caches with file protection: 30-day lifetime,
100 snapshots, 8 MB encoded globally, and up to the latest 500 projected messages
per bot. Messages over 16 KB are omitted. Search returns at most 100 matches and
asks the user to refine at the cap. Unknown roles, tool output, credentials from
prompt cards, inflight text, and drafts are not indexed.

A message result holds the selected immutable snapshot and opens a read-only
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
