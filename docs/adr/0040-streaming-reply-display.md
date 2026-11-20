# 0040. Streaming reply display

Area: chat-streaming

## Keep flushed plus pending text equal to the full received stream

Tokens are deduplicated at append time, so flushing pending assistant text is plain
concatenation. When `ChatViewModel` flushes through `StreamingRevealGate.cut`, only the head
of the buffer moves into the visible message and the held fragment stays in
`pendingAssistantText`. That keeps the replay-dedup invariant that flushed plus pending
text is the full received content.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobile/Features/Chat/StreamingRevealGate.swift`

## Reset replay counters but keep dedup armed when dropping stream buffers

Because chunks are deduplicated at append time, the replay matched-prefix counters can
reference unflushed content, and dropping the pending assistant and reasoning buffers makes
them stale. `ChatViewModel` then resets only `activeStreamReplayMatchedPrefixLength` and
`activeStreamReplayMatchedReasoningLength`, not the replay state: the replay connection may
still be live (for example `loadOlderMessages` pagination mid-catch-up), so dedup must stay
armed.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Snap follow scrolls while a reply streams

`ChatView.scheduleFollowScroll` animates the follow scroll only when no stream is active
(`viewModel.activeStreamID == nil`). Streaming updates land about every 48 ms, so an
animated follow is cut off by the next one and never settles; live-stream follows snap.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`
