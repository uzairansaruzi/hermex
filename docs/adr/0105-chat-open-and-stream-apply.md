# 0105. Chat open and stream apply

Area: performance

## Overlap the first transcript request with the push animation

`ChatViewModel.prepareInitialMessageLoad` performs the fast, local portion of an existing session's first load and sends its transcript request. `ChatView` applies the response only after its navigation appearance completes (`loadMessages(usesInitialPrefetch:)`), so rendering a richer transcript cannot stall the system push animation while the round trip overlaps it. A Hermes chat shows its cached transcript there instead, and attaches from `loadMessages`.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Defer chat startup work until the push transition completes

`ChatView` keeps transcript reconciliation and other state-heavy startup work out of the system navigation transition, waiting for its initial appearance to complete. The cache read and the transcript request go out before that gate.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Run stream replay dedup matching only on reconnect replays

Normal streams cannot contain replayed content, so `ChatViewModel`'s reasoning and assistant-token append paths skip building the full flushed plus pending content before appending every token. The expensive effective-content comparison runs only on reconnect replay paths, where it suppresses duplicated events.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Patch only the streaming reply's row when its text grows

`ChatViewModel.replaceStreamingReply` puts the streaming reply, its text grown by a flush, back into `messages`. When the extra text can't change the transcript's structure, only that reply's row is patched; any other change re-derives the whole transcript through the `messages` observer (#1417).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
