# 0036. Hermes chat turns

Area: chat-streaming

## Run Hermes turns through the shared stream delegate

`HermesChatTurnCoordinator` runs a Hermes session's turns in the main chat (#1010). It owns
the session's `HermesConversation`, which attaches, replays and reconnects, and reduces the
engine's ordered frames onto the chat's `ChatStreamCoordinatorDelegate`, so message
building, pacing and run endings are the webui path's. Text is delta-driven, and because the
engine drops repeated frames by `seq`, appends never deduplicate by text. Each prompt, steer,
redirect and stop is one `write`, never resent; a Send or Queue uploads its staged files
first (#1012).

Settled history comes from REST transcript pages (#1047), 100 rows at a time, newest first.
An attach's rebuild signal (a gap, a reset replay, a new runtime) re-reads the newest rows,
back to the rows held, and lays the snapshot's in-flight turn after them; a turn the host
saved in full re-reads them so its rows take their durable ids, as does a turn's end after a
running turn's rebuild (#1531).

A turn's identity is the stored key plus the host's `turn_started_at`, in place of a webui
stream id. A turn starts at `message.start`, an accepted send or a running snapshot, and
ends once `message.complete` and `session.info {running: false}` have both arrived.

Each turn drives the shared Live Activity at the same points (#1014) under the key
`hermes:<profile>:<root>` (#1179), the chat's identity, so a reconnect inside the turn adopts
the same activity after a legacy compression moved the stored key. Its tap is the session's
link (#1176) and its relay pushes come under the stored key, moved with it. A bot's
`.canonicalChat` (#1145) keeps the Bot identity instead (`AgentRunActivityBot`), whose tap
opens the bot's chat; a Bot Chat row opened by its key keeps the session's.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Start a turn from a send's reply only if its frames haven't

The turn's own frames, such as `message.start`, can land before the send's reply. When a
Send's reply says it started a turn, `HermesChatTurnCoordinator.submit` calls `beginTurn`
(and sets `awaitingStart`) only if `turnsStarted` is unchanged and no stream is active;
starting unconditionally opens a duplicate turn.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Ignore an idle report before a sent turn's first frames

A turn begun by a send's reply has not seen its own frames yet, so an idle `session.info`
arriving then is the report from before the turn. The guard
`pendingEnding != nil || !awaitingStart` in `HermesChatTurnCoordinator` keeps that stale
idle report from finishing the new turn.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Treat errors after message.start as pending failures

After the turn's own `message.start`, an `error` frame can be a warning the turn goes on
past, such as a model switch that failed, and the host always settles the turn with
`session.info {running: false}`. `HermesChatTurnCoordinator.apply` therefore only sets
`pendingEnding` to failed, and the turn fails at settle unless a completion came. Before
`message.start`, as when the host refuses the turn, nothing else follows, so the error ends
the turn at once.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Treat a failed turn's text as its error unless partial

On `message.complete`, a failed turn's `text` is its error, not a reply, unless the host
marks it `partial`. `HermesChatTurnCoordinator` forwards the text as the reply
(`hermesTurnDidComplete`) only when the turn did not fail or is partial; the outcome row
says why it failed.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Treat sends behind a lost canonical turn as follow-ups

A canonical host's turn lost across its restart (`pending` status `unknown`, #1602) still
holds the canonical queue. `HermesChatTurnCoordinator.submit` counts a send as behind a
running turn while `lostTurn` is set, so it waits behind the lost turn like a follow-up
instead of starting a turn.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Withdraw canonical queued admissions before interrupting

`HermesChatTurnCoordinator.interrupt` stops the running turn with `session.interrupt`; it
returns false when there is none or a stop is already in, and idle still waits for the
turn's own ending frames. The dashboard host also discards its queued prompt, withdraws
open requests and denies pending approvals, but a canonical host keeps its queue through an
interrupt, so the known queued admissions are withdrawn first with `prompt.cancel`, then the
running generation is interrupted (#1341, decision 3). One a newer turn refuses throws
`HermesFenceRefusal` and sends nothing more. Afterwards only the non-canonical path clears
`queuedPrompts`: a canonical queue lost only what was withdrawn, and its `pending` reports
the rest.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Clear queued prompts on stop only for dashboard hosts

When a turn ends cancelled, a stop from any client has made a dashboard host discard its
queued prompt and withdraw its requests, so a receipt for this chat's queued prompt would
never send, and `HermesChatTurnCoordinator` clears `queuedPrompts`. A canonical host keeps
its queue and reports it through `pending`, so `queuedPrompts` is left alone there.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Ignore message.complete for a withdrawn canonical admission

A queued admission a canonical host withdrew before it ran settles with a
`message.complete` carrying an `admission_id` and a null `execution_generation`. No turn
ran, so `HermesChatTurnCoordinator.apply` ignores it and the running turn goes on instead
of finishing.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Serialize Hermes Edit, Regenerate and /retry

On a canonical host, an Edit, Regenerate or `/retry` is a rewind followed by a send of its
own (#1603), so a second one started meanwhile could share the first one's rewind and run
the agent twice. `ChatViewModel.isChangingHermesHistory` is set while one is under way, and
a second one waits for it.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
