# 0035. Hermes chat requests

Area: chat-streaming

## Never retry a Hermes request answer

`HermesChatRequests` holds a Hermes session's host requests in the main chat (#1011):
approvals, questions, sudo and secret prompts, Desktop's own tasks and `manage_connections`
operations (#1141). `HermesChatTurnCoordinator` feeds it the session's request frames,
envelopes parse with the Bot models (`BotServerRequest`, `BotConnectionOperation`), and
answers go out through the engine's guarded writes, once each, from a tap. Nothing is
retried (#508): a lost reply reconnects, and the attach's `open_requests` and
`pending_connection` say whether the request is still open.

When `HermesChatRequests.deliver` gets no verdict, it keeps the card answerable for a
deliberate second tap, says so, and resends nothing. If the host did settle it, its
`request.cancel` retires the card and the warning with it; a reattach here would drop both
first. A reply that lands after its request already left warns about nothing.

The list is the host's: live envelopes, `request.cancel` withdrawals, and the
`open_requests` an attach's replay and snapshot carry, which replace it. A Desktop task gets
a card that is only shown, never answered, since a reply from here would take the request
from Desktop, which answers it. Password-vault prompts and unknown methods get no card and
are never answered, yet any open request still means the session waits for someone.
`set_theme`'s `theme.apply` and `theme.pick` are the exception (#1727): answered at once
without a tap, they never join the list (`HermesThemeRequest`). Credential and setup values
pass straight to the dispatch and are never kept.

A connection operation is an event plus an RPC, not a server request: `connection.request`
opens it, each newer `connection.update` replaces it, its settled frame closes it, and the
snapshot's `pending_connection` restores it. Account operations' global updates never reach
a session, so they never touch its card.

Lives in: `HermesMobile/Features/Chat/HermesChatRequests.swift`

## Skip batch questions with per-question empty locks

`HermesChatRequests.skipQuestion` skips the question on screen with empty answers: an empty
lock for each outstanding batch question, never a bare answer, which the host reads as
cancelling the whole batch. A single question gets one empty `request.answer`.

Lives in: `HermesMobile/Features/Chat/HermesChatRequests.swift`

## Release a connection operation before a Steer or Queue message

`HermesChatRequests.continueConnection` releases the open operation before a Steer or Queue
message, as Desktop does, so the message does not wait behind the blocked tool until its
deadline: one `settled_by: "continue"`, never retried. A refusal (most often: it had already
settled) lets the message go; a lost reply warns on the card, as a lost row answer does,
then throws, and the message is held. It shares the card's one answer at a time
(`answeringRequestID`): an answer still out holds the message, and the card waits while
Continue is out. An operation that changed before the write holds the message too.

Lives in: `HermesMobile/Features/Chat/HermesChatRequests.swift`

## Never send a session-scoped bypass off the host cannot clear

Turning the approval bypass off in a Hermes chat clears only the session's `yolo` flag. A
bypass the host sets itself (a `--yolo` launch) stays on in the `session.info` written ahead
of the reply, so the row keeps reporting it and offers no second Turn off. A host that
approves everything itself (`approvals.mode: off`) shows the bypass too, and the switch never
sends a session-scoped off, which cannot clear it.

Lives in: `HermesMobile/Features/Chat/HermesChatRequests.swift`, `HermesMobileTests/HermesChatRequestTests.swift`
