# 0042. Bot room transcript

Area: chat-transcript

## Build room transcripts eagerly over a bounded window

Member replies in a bot room are hosted selection documents, and a lazy stack places unbuilt rows from an estimate, so the jump to a search hit missed on a cold open (#553). `BotRoomView` builds its transcript in an eager stack over a bounded window, `BotRoomTranscriptWindow`, which keeps the build to the newest page (`pageSize`, 50 events). `BotRoomTranscriptWindow.start` gives the index of the first shown event in the sequence-sorted `events`; an anchor outside the events (a reconnect restored a trimmed transcript, or the room restarted) falls back to the newest page. Its `keeping` argument widens the window to a search hit that is present, so the hit's row is built by the time the jump runs (#553).

Lives in: `HermesMobile/Features/Bots/BotRoomView.swift`

## Keep room thread rows on stable identity

`BotRoomTranscriptRow` uses a stable thread identity for rows in the overview, and exact sequence identities in thread detail and unthreaded history. A reply changes its thread's latest event, and it must not replace its overview row's identity; thread identity also survives activity reordering.

Lives in: `HermesMobile/Features/Bots/BotRoomView.swift`

## Yield before jumping to a room search hit

A pushed thread destination in `BotRoomView` lays out after the overview's synchronous search callback. The jump awaits `Task.yield` so those materialized rows exist before `proxy.scrollTo` runs.

Lives in: `HermesMobile/Features/Bots/BotRoomView.swift`
