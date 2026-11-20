# 0034. Chat stream liveness and recovery

Area: chat-streaming

## Keep the transport fresh interval between heartbeat cadence and reconnect interval

`ChatStreamCoordinatorTiming.transportFreshInterval` is how long a quiet transport still
counts as provably alive. It must sit above the server's ~5 s SSE heartbeat cadence, or a
healthy stream between two heartbeats reads as stale, and below `reconnectInterval`, or a
dead transport is never escalated before the reconnect deadline (#227).

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Treat SSE heartbeats as transport liveness

A heartbeat proves the connection is alive during a semantically quiet window (the model
thinking, a slow tool call) without carrying progress (#227). While transport activity is
within `transportFreshInterval`, `ChatStreamCoordinator` stays idle and skips status polls;
a genuinely silent transport still escalates once past it. On `.heartbeat` it drops an
already-shown "Checking stream" (`.checking`) state to idle at once, but never demotes
`.reconnecting`: that chip belongs to the reconnect flow until real progress lands.

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Escalate stale-stream recovery only from a still-checking state

Stale-stream recovery in `ChatStreamCoordinator` sets `recoveryState = .checking` before
awaiting a status probe. After the await, both the success and the failure path reconnect
only if the state is still `.checking` for the same active, unsuspended stream. If a
heartbeat or real progress demoted it to `.idle` mid-flight, the transport just proved
itself alive, so recovery must not resurrect the chip or churn a live connection; the next
recovery tick re-evaluates from scratch (PR #238 review).

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Finalize a stream the server reports inactive

When a reconnect-after-suspend or stale-recovery status probe says the stream is no longer
active, `ChatStreamCoordinator.finalizeInactiveStream` completes from the just-refreshed
transcript if an assistant reply surfaced, and otherwise finalizes as failed. Either branch
ends the Live Activity, so it never dangles on "running" after the run is over (#246).
Only those two paths use it, because no live SSE stands behind them. It records a failure
against the `runStartedAt` captured before the awaited transcript load, since a load that
finds the stream gone clears the live run start; the chat then still alerts for it, the way
the Live Activity says "Response failed" (#862).

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Let the live SSE own completion in the foreground refresh

`ChatStreamCoordinator.refreshTranscriptIfCompleted` is a foreground safety net. When the
live SSE is still connected and the refreshed transcript has no assistant reply after the
latest user message, it keeps waiting for the real `.done` instead of finalizing, because a
status poll can briefly report inactive. This is the deliberate counterpart to the
reconnect-after-suspend fix, and why #246's `finalizeInactiveStream` excludes this path.

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`, `HermesMobileTests/ChatStreamCoordinatorTests.swift`
