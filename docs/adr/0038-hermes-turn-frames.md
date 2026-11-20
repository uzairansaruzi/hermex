# 0038. Hermes turn frames

Area: chat-streaming

## Treat only reasoning.delta as reasoning

The Hermes turn stream emits `thinking.delta` and `reasoning.available`, and
`HermesChatTurnCoordinator.apply` reads neither as reasoning on purpose: `thinking.delta`
is spinner text and `reasoning.available` carries the answer itself. Only `reasoning.delta`
is reasoning content; the working row already says Hermes is working.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`, `HermesMobileTests/HermesAgentFixtureTests.swift`

## Drop held deltas the snapshot reply already holds

The host appends each delta to the in-flight reply before it emits the frame, so deltas
emitted while an attach's snapshot was read are both in its text and held.
`HermesChatTurnCoordinator.heldDeltas` finds them among the held deltas after the replay's
`sequence`: they are the turn's first held deltas, before any `message.start`, and match
whole, as the longest run that, after `replayed` (the reply text the replay carried), ends
the reply. The snapshot has no `seq`, so only text that repeats itself across that boundary
stays ambiguous.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Keep the webui replay text matcher off for Hermes

`HermesChatTurnCoordinator.isReplayConnection` is always false. The engine drops repeated
frames by `seq`, and a rebuild drops the held deltas its snapshot holds, so the webui text
matcher in `ChatViewModel` stays off for Hermes chats.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## End the compacting line on /compress's ready status

`HermesChatTurnCoordinator` starts the Compacting context line on `status.update` kinds
`compacting` (auto-compaction, with its heartbeat) and `compressing` (`/compress`), and
ends it on `compacted`. It also ends it on `/compress`'s `ready`, which the host sends as
`{kind: "status", text: "ready"}` (#1734).

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## End compaction on any idle session.info

`HermesChatTurnCoordinator` calls `endCompaction` on every idle `session.info`, even with
no turn shown, because an idle `/compress` never sends its end.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## End compaction on reattach reset

A reattach can miss the `compacted` frame, so
`HermesChatTurnCoordinator.conversationDidReset` ends any shown compaction. A compaction
still running sends its heartbeat again, which shows the line again.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Treat an empty Hermes plan at revision 1+ as a clear

`HermesPlanState` holds the newest plan a session's host reported, for every Hermes chat,
and applies `todo.updated` and `todo_state` revision-monotonically: an older revision never
replaces a newer one. An empty list at revision 1 or later is the host clearing the plan
(`_normalize_todo_state`), which hides it until a newer revision. An unused store reports an
empty list at revision 0, which is neither a plan nor a clear, so `HermesPlanState.apply`
ignores it.

Lives in: `HermesMobile/Features/Chat/HermesChatActivity.swift`
