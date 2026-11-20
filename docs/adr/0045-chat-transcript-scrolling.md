# 0045. Chat transcript scrolling

Area: chat-transcript

## Preserve the reader's offset with ChatScrollPositionController

`ChatScrollPositionController` keeps the reader's exact vertical position through layout changes SwiftUI would otherwise move them for. It snapshots the UIKit scroll geometry, then corrects during the following layout passes for a bounded window, deliberately without animation, since it preserves a position rather than navigating to one. **Prepend:** older rows go above the reader and the offset shifts by the net content-height growth; `ScrollViewProxy.scrollTo(_:anchor:)` can only align a row to a coarse anchor, which loses the gap the Load Older button occupied and causes a visible hop. **Hold:** a disclosure toggle resizes a row below the reader and the offset must not move; SwiftUI can re-apply a default anchor on that size change (seen at the exact top after a status-bar scroll), which shows as an offset change in the same run-loop turn as a size change and is put back, while any other offset change (VoiceOver, a hardware keyboard, a follow scroll) is deliberate and releases the hold. **Reflow:** a column-width or text-size change rewraps every row and the raw offset lands on another passage (#1414); rows, and the plan and compression card between them, report frames through `rowFrameChanged` under the layout they were measured in, the first frame of a new layout captures the reader's place from the old frames, and the anchor row's new frames restore it; a reader at the top stays at the top through any change in the bars' insets and is undone like a hold with its resync (#1528), a reader following the live edge is left alone, as is a prepend or hold already in flight, and otherwise it ends like a hold without the resync. **Handoff:** after a size-class change rebuilt the transcript (`ChatContinuity`), the new controller keeps the old one's reading place as a reflow does and undoes the bottom anchor SwiftUI opens a new transcript at. Any user movement releases the hold.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`

## Hold prepend compensation for a bounded window

Text and attachment layout can settle over several run-loop passes after older rows are prepended. `ChatScrollPositionController.restoreAfterPrepend` keeps applying the same net-height correction for a short bounded window (`beginPreservation(mode: .prepend, window: 1)`) rather than once, then releases ownership back to normal scrolling.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`

## Resync SwiftUI with its own scroll after reverting its offset

When a hold has to undo an offset SwiftUI applied, SwiftUI's own notion of the offset is stale, and lazy rows it believes are off-screen stop hit-testing until a scroll SwiftUI performed itself resyncs it. `ChatScrollPositionController` sets `didRevertSwiftUIOffset` in that case, and `resyncAfterHold` is that scroll.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`

## Resync SwiftUI only when a hold sits at the transcript top

The resync is a SwiftUI scroll to the transcript's top, so it only describes the held position when that position is the top. SwiftUI's anchor re-application has only been seen there (after a status-bar scroll). `ChatScrollPositionController.shouldResync` requests it only at the top; anywhere else the controller leaves SwiftUI alone rather than make the reader hop.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`

## Release the disclosure pin on content-size quiet, not a fixed window

The offset pin a disclosure toggle arms releases once the content size has been quiet for `ChatScrollPolicy.disclosureHoldQuietPeriod` (0.3 s). Lazy rows can keep laying out well past the animation, and SwiftUI re-applies the bottom anchor on each of those size changes after a status-bar scroll, so a fixed window is not enough. `disclosureHoldMaximum` (2 s) caps the hold for transcripts that never go quiet.

Lives in: `HermesMobile/Features/Chat/ChatScrollPolicy.swift`

## Wait for momentum before treating a drag release as final

Finger-lift velocity is not a reliable signal: a gentle fling can report zero and still decelerate. `ChatScrollPolicy.dragSettleDelay` (0.16 s) is how long a finished drag waits for momentum to announce itself before the release position is treated as final.

Lives in: `HermesMobile/Features/Chat/ChatScrollPolicy.swift`

## Judge a drag's follow opt-out at finger lift

`ChatScrollObserver`'s coordinator records whether the reader was at the bottom when the finger lifted, before waiting `dragSettleDelay` for momentum. Streaming growth during that momentum-detection window must not turn a release at the live edge into an opt-out from follow.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`

## Re-pin to the bottom without animation after a transcript relayout

`ChatViewModel.transcriptRelayoutScrollToken` is bumped whenever something re-lays out the transcript under the reader without adding a message: the server transcript replacing the lighter cache-first render of a cold open (#289), or the skill catalog turning sent `/slug` text into chips. The richer server content (tool-call and reasoning cards, content parts) is taller than the cached render, so `ChatViewModel.loadMessages` bumps the token once the reconcile lands, and the view puts a reader who was pinned to the bottom back there without animation; an animated re-pin shows the height growth as a visible scroll jump.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
