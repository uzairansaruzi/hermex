# 0032. Chat stream attach and replay

Area: chat-streaming

## Reattach with the run journal cursor

A cursorless attach can replay the run from the start and duplicate text already on screen
(#599). On reconnect, when the server reports `replay_available`, `ChatStreamCoordinator`
resumes from the last event this process rendered with
`runJournalReplayAfterSeq(from: lastEventID)`. A cold process with no snapshot asks the
journal for the whole run, so the loaded partial transcript fills in before `done`. A
snapshot or an unparseable cursor keeps an ordinary connection.

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Drop the old stream's resume cursor when adopting a new stream

`ChatStreamCoordinator.restoreLoadedStreamSnapshot` restores a stream's snapshot while a
session load adopts it. Adopting a different stream first drops the previous stream's
resume cursor, so its seq is never sent as `after_seq` for the new run (#599).

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Fence a session load by stream identity, not run generation

After an awaited session load, `ChatStreamCoordinator` checks
`activeStreamID == activeStreamIDBeforeLoad` rather than `runGeneration`. A same-stream
`start()` (foreground reconnect or replay) bumps `runGeneration` without replacing the
server run, so a generation check would treat that restart as a new authority and drop the
uncached optimistic row.

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Use the initial prefetch only if the active stream is unchanged

`ChatViewModel.takeInitialSessionPrefetch(usable:)` clears the stored prefetched transcript
request and hands its task over only to the initial load, and only while `activeStreamID`
matches the one the request went out under; otherwise it cancels the request. A session
response fetched before a stream started would read as that stream having ended.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Reload the transcript before attaching to an existing run

When a webui send fails because the session already has an active stream (an `APIError`
carrying `activeStreamID`, not `session_rotated`), `ChatViewModel.performChatSend` reloads
the server transcript first, then restores the stream snapshot and starts
`streamCoordinator` on that stream. The run may have started outside this view model;
reconciling first makes the SSE tokens attach to the persisted assistant turn instead of
creating a second bubble holding only the tail.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Hand the Hermes chat its offline cache before the attach starts

`ChatView` calls `ChatViewModel.reconnectStreamIfNeeded` as it appears, before its first
load, so a Hermes chat's attach can begin there. The method therefore sets `hermesCache`
from the `ModelContext` before `turn.reconnectIfNeeded`, so the attach can write what it
reads (#1144).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobile/Features/Chat/ChatView.swift`
