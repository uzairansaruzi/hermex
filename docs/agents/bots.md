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

History is memory-only. Open/recovery replaces it from a full resume snapshot.
Replay detects discontinuity but never appends text to an overlapping snapshot.
Live events coalesce inflight snapshot reads using `omit_messages`; that installed
handler path avoids history database reads. Completion and session-state events
request full history. There is no transcript cache or speculative REST adapter.
Socket loss shows disconnected/unknown. Foreground and explicit reconnect reload
canonical identity, history and current state before enabling commands.

The transcript follows a stable trailing anchor until the user scrolls into
history; Latest resumes following. Coalesced text snapshots use synchronous
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

Bot drafts extend `ChatDraftStore` with server + connection UUID + Profile context.
Before sending, the client flushes an unresolved marker to disk. An acknowledged
send consumes the draft; explicit admission failures preserve its text. An
ambiguous outcome stays held across navigation and relaunch. The user can check
Desktop and explicitly discard the held text; that action never resends it.
Identical text in recovered history cannot reliably attribute a submission.

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
not as a new prompt. Unknown result shapes stay ambiguous and held.

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
malformed, oversized or missing asset leaves the row on its letter tile. Desktop's
animated faces are not ported; the phone shows the static asset only.

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
