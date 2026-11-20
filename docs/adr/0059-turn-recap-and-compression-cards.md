# 0059. Turn recap and compression cards

Area: chat-transcript

## Collect every tool group in the current turn for the changes recap

`ChatViewModel.latestTurnToolCalls` drives the in-chat file-changes recap card and the composer's "N changes" capsule (#316). A turn often spans several assistant messages (tool calls on one, the final text on the next), and the archived tool group anchors to the first of them. So it collects every completed group in the current turn, since the last user message, plus any still-live calls, not just one anchor.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Recompute the compression card when its metadata changes

`ChatViewModel.recomputeCompressionReferenceCard` is not driven by the `messages` and `messagesOffset` observers alone: `applyCompletedStreamSession` can update the compression metadata without reassigning `messages`, so metadata changes recompute it too. An equality guard keeps the overlapping triggers observer-silent.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Clamp unresolved compaction anchors to the top

The server's compression anchor index counts visible messages from the absolute start of the session, while the app holds a `msg_limit` tail window. `CompressionAnchorResolver` shifts it by the raw `messagesOffset`, which over-corrects (the raw count is at least the visible count); that only biases unresolved anchors toward the top clamp, the degraded behavior the issue asked for when the anchor predates the loaded tail. Matching the anchor message's key remains the precise path.

Lives in: `HermesMobile/Features/Chat/CompressionAnchorResolver.swift`
