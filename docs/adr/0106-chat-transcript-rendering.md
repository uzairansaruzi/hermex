# 0106. Chat transcript rendering

Area: performance

## Pass stable inputs to non-streaming transcript rows

`ChatTranscriptView` scopes live-streaming state to the row that actually displays it. Non-anchor, non-streaming rows receive stable empty or nil values so their inputs don't change on every ~16 ms flush; combined with the `.equatable()` wrapper, SwiftUI then skips re-evaluating their markdown-heavy bodies while a response streams in.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptView.swift`

## Compare transcript rows by value inputs only

`ChatTranscriptMessageBlock` defines equality over its value inputs only. The closures are pure functions of these values (for example `actionContext` is determined by `transcriptMessage`, and in a Hermes session by the observed set of rows that can rewind, whose change invalidates the row itself), so two blocks that compare equal render identically. This lets `.equatable()` skip rows whose data is unchanged even though their closure props are recreated on every parent body pass.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptView.swift`

## Read the streaming scroll trigger in a leaf view

`ChatTranscriptView` reads the stream's coalesced scroll trigger only in `StreamingFollowTrigger`, which runs `onFire` each time it bumps. The trigger bumps once per drain tick while a reply streams and feeds only this scroll. Reading it in a leaf keeps each bump from re-running the chat screen's content (transcript derivations, every row's equality check, the composer) just to scroll.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptView.swift`

## Load transcript media only once it is on screen

The transcript is an eager stack, so every row mounts when a chat opens. `LoadsOnceVisibleModifier` calls `admit` with `id` the first time a media leaf is on screen, so opening a chat loads only the media the user can see; the leaf keeps the admitted id in its own `@State` and keys its load `.task` by it. Admission latches per `id`: scrolling away never withdraws it, so a load in flight keeps running, and a new `id` waits until the leaf is on screen again.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`

## Keep delegated-work observation in its leaf

`HermesDelegatedWorkInlineView`, a bounded preview at the live end of the transcript, observes the roster itself, so tool updates stay in this leaf and the transcript only observes whether any workers are active. It is equal by `work`, which `onOpen` opens, so a stream tick above it skips its body. `HermesDelegatedWork` stores the count of every live worker, the omitted included, apart from `workers`, whose rows change with each tool a worker calls, so a toolbar reading it redraws only when the count does.

Lives in: `HermesMobile/Features/Chat/HermesDelegatedWorkView.swift`, `HermesMobile/Features/Chat/HermesDelegatedWork.swift`

## Tick the run-status pill inside a label-only TimelineView

`ChatActiveRunStatusView`, the run-status pill above the composer shown while the transcript is scrolled away from its bottom, never animates: a static dot marks it. An active run's elapsed time ticks once a second inside a `TimelineView` that wraps only the label, so the tick re-renders nothing else and stops when the pill hides.

Lives in: `HermesMobile/Features/Chat/ChatActiveRunStatusView.swift`

## Use overlay edge fades, not masks, in the scrolling transcript

`HorizontalOverflowFadeStyle` has two styles. The alpha mask fades the content itself, so any surface behind it (glass) shows through, but it costs an offscreen pass, so it is kept to fixed chrome. The overlay draws a gradient from clear to the host's background colour over the edge with no offscreen pass, so it suits views in a scrolling transcript.

Lives in: `HermesMobile/Features/Chat/HorizontalOverflowEdgeFades.swift`

## Own a diff's viewport width in its scroll body

`DiffCodeBlockScrollBody`, the horizontal-scroll layout of a settled diff, owns the viewport width so the post-layout width write re-renders only this view, not `ChatCodeBlock`, which would re-parse the diff.

Lives in: `HermesMobile/Features/Chat/MarkdownDiffCodeBlock.swift`
