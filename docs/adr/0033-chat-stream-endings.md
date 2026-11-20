# 0033. Chat stream endings

Area: chat-streaming

## Fence late content after a response completes

`ChatStreamCoordinator.isTerminalContentFenceActive` is set when the response completes and
is not cleared by `finishStream` (which does reset `hasCompletedCurrentResponse`), so
content queued after `done` then `streamEnd` still cannot reach the transcript. Title and
metering events still pass as session metadata, and a settled completion is never re-ended
by a late error or cancel. Only the next run start, new-response preparation, or session
load clears it (#288 review).

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Finish teardown exactly once on terminal events after done

After a settled completion, `ChatStreamCoordinator.handle` routes `transportError`,
`cancelled`, `error` and `streamEnd` to `finishStream()`, so teardown happens once, without
a second Live Activity end or repeated delegate finish, drain, and title-refresh side
effects. A `transportError` after `done` must still finish (snapshot cleanup, queued-slash
drain, completed-title refresh); it used to fall through to `handleTransportError`
(PR #295 re-gate).

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Ignore the transport error from webui's close after cancel or error

webui closes the socket right after it sends `cancel` or `error`, and the SSE library
reports that close as a transport error. `ChatStreamCoordinator.handleTransportError`
returns early once the transport is finished, so that error never replaces the server's
error message and a cancel never shows an error.

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`, `HermesMobileTests/ChatStreamCoordinatorTests.swift`

## Keep approval monitoring past the chat stream's end

A pending approval belongs to the server, not to the chat transport, and its event can
arrive on its own SSE stream after the chat response completes.
`ChatPendingActionCoordinator.stopMonitoringForStreamTransition` therefore stops approval
monitoring only when the stream connection is suspended, not when the response ends.

Lives in: `HermesMobile/Features/Chat/ChatPendingActionCoordinator.swift`

## Queue a missed steer before checking whether the run ended

When a webui steer returns `.runEnded`, `ChatViewModel` enqueues the message at the front
first and only then calls `streamCoordinator.refreshTranscriptIfCompleted`. If the run is
over and the transcript has the reply, the coordinator finishes the run, which drains the
queue as a normal send; otherwise the live stream still owns the ending and its own finish
drains the queue. Checking first would let that drain find the queue empty.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Clamp the run start and let the earliest known start win

`ChatStreamCoordinator.seedActiveRunStart` adopts a server-known start for the active run,
replacing the local stamp `activeStreamID`'s observer laid down; every seed is stable
across re-entry, so a same-stream reattach sharpens the counter rather than restarting it,
and a nil seed leaves the discovery stamp alone. A future-dated seed (clock skew between
phone and server) is clamped to `now` so "Working for" never counts backwards. Reloading
the same running session re-seeds the same skewed stamp later, so clamping alone would pin
the start to a fresh `now` and restart the counter on every reload; the earliest start
known for the stream wins, and a re-seed can only move it earlier.

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`, `HermesMobileTests/ChatStreamCoordinatorTests.swift`
