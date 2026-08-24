# Long streaming assistant messages: performance investigation

> **Status:** draft investigation for issue [#291](https://github.com/uzairansaruzi/hermex/issues/291)
>
> **Repository revision investigated:** `b1605f91f5f6d06f4b505578564268436f769c9b`
>
> **Validation status:** source inspection only on Linux. This environment does not have Xcode, `xcodebuild`, `xcrun`, an iOS Simulator, or Instruments.

## Problem statement

When Hermex receives a long assistant response, especially one containing rich Markdown, code blocks, tables, tool output, or reasoning, the app can become very slow or appear to stop loading correctly. The slowdown is most noticeable while the response is still streaming, and may also affect scrolling through a long transcript.

This document records the current source-level evidence and defines the validation required before a code fix is considered ready. It is deliberately an investigation document, not a claim that a fix has been implemented or verified.

## Findings on current `master`

### A. The transcript still eagerly realizes rows

`HermesMobile/Features/Chat/ChatTranscriptView.swift:208` uses:

```swift
VStack(spacing: transcriptMessageSpacing) {
    // ...
    ForEach(displayedTranscriptMessages) { transcriptMessage in
        // ...
    }
}
```

This means all loaded transcript rows can be constructed and measured rather than only the visible window. This is a real, related cost for conversations with many messages, but it is already tracked independently by:

- issue #32 — improve long-conversation transcript scroll performance;
- PR #33 — lazy transcript rows (still open).

This investigation must not silently duplicate or absorb that work. Any `LazyVStack` change needs its own scroll-position and pagination validation, particularly around the `.sizeChanges` anchor restored by PR #137.

### B. Settled Markdown and streaming Markdown have different paths

The merged optimisation from issue #260 / PR #261 memoizes settled Markdown math layouts. That reduces repeated work for unchanged assistant messages.

The streaming path intentionally does not use that cache. In `HermesMobile/Features/Chat/MarkdownRenderer.swift:84-143`, `StreamingMarkdownRenderer` updates as `content` grows and calls:

```swift
MarkdownMathLayoutCache.uncachedLayout(for: displayedContent)
```

This avoids inserting a new cache entry for every token, but it also means the growing response is repeatedly parsed. The following operations inspect the accumulated content on successive updates:

- `StreamingMarkdownBlockSplitter.split(content)`;
- `StreamingTextFadeTailSplitter.split(...)`;
- Markdown/math segmentation and layout;
- MarkdownUI layout for the active content.

The source currently does not retain an incremental parse/split state that makes settled blocks independent of later appends.

### C. The token hot path repeatedly rebuilds pending text

In `HermesMobile/Features/Chat/ChatViewModel.swift:4328-4343`, each received token is appended to the pending buffer. Before de-duplication, the code constructs an effective string from the already-flushed content and all pending chunks:

```swift
let flushedContent = messages.first(where: { $0.messageId == messageID })?.content ?? ""
let effectiveContent = flushedContent + pendingAssistantTokenChunks.joined()
let remainder = deduplicatedReplayToken(token, existingContent: effectiveContent)
```

At flush time, `flushAssistantTokens` joins the pending chunks again before appending them to the visible message. With a delayed MainActor or a fast server stream, the pending buffer can become large. Repeated whole-buffer joins and full-string concatenation can amplify the rendering cost.

This needs measurement before changing the representation, because replay de-duplication depends on the exact effective content and must remain correct during reconnects.

### D. State changes invalidate the active row and trigger layout/scroll work

The view model publishes a new `messages` value after each visible streaming flush. The active row is then laid out again. `ChatTranscriptView` also observes `streamingScrollTrigger` and may call `onScrollToLatestContent` while following the latest message.

`MessageBubbleView` applies an animated height change to the active assistant row while streaming. Therefore, one flush can combine:

1. state publication;
2. Markdown parsing and layout;
3. row height measurement;
4. animated height growth;
5. bottom-follow scrolling.

The existing `.defaultScrollAnchor(..., for: .sizeChanges)` contract must remain intact when the user is still following the latest message and must not pull the reader back after manual scrolling away.

## Hypotheses to test on macOS/iOS

Ranked by likelihood and expected impact:

1. **Eager transcript row realization** dominates when the conversation contains many messages. Test with a long persisted transcript and compare current `VStack` with a controlled `LazyVStack` experiment, while measuring opening and scrolling.
2. **Repeated streaming Markdown work** dominates for one very large assistant message. Test with identical streamed content split into small SSE chunks and measure main-thread time and frame responsiveness.
3. **Pending token joins and string concatenation** amplify backlog under a fast stream or delayed UI. Test with controlled chunk rates and compare total characters copied/allocations.
4. **Scroll-anchor/layout feedback** causes visible jank when Markdown height changes while following the bottom. Test while streaming, then scroll away and confirm the app stops automatic repositioning.
5. **Tool/reasoning arrays and row invalidation** cause unnecessary re-evaluation of settled rows. Test with and without tool/reasoning activity and inspect SwiftUI body/layout time.

## Required instrumentation and fixtures

Use a macOS/Xcode environment with the `HermesMobile` scheme and the reference iPhone simulator. Create deterministic fixtures rather than relying only on a live model response:

- plain Markdown response around 8 KB, 32 KB, and 80 KB;
- fenced Swift/Python code blocks, including a long code block;
- table-heavy response;
- list/blockquote response;
- inline and display math response;
- tool-heavy transcript containing large tool output;
- transcript with at least 200 loaded rows;
- SSE token chunks at a controlled cadence and at a deliberately high cadence.

Record:

- main-thread time;
- SwiftUI body/layout time where available;
- allocations and transient memory;
- frame rate/hitches;
- time to first visible content;
- time to finish opening a cached session;
- scroll responsiveness;
- ability to cancel a stream.

## Proposed implementation boundaries

A future implementation PR should be split into reviewable slices where possible:

1. Add pure regression tests for streaming segmentation and exact final-content preservation.
2. Keep completed/stable Markdown blocks and their parsed representation stable; only reprocess the active tail.
3. Replace repeated pending-buffer `joined()` work with an equivalent incremental representation, preserving replay de-duplication and cancellation semantics.
4. Keep live state scoped to the active row and avoid passing changing arrays to unrelated transcript rows.
5. Treat lazy transcript row realization as separate work under #32/#33 unless the maintainer explicitly chooses to combine it.

No implementation should remove the `.sizeChanges` scroll anchor, reduce the user-visible page size, remove Markdown features, or add a dependency merely to improve a benchmark.

## Acceptance criteria

- Final assistant content is byte-for-byte identical to the server content for normal streams and replay/reconnect streams.
- Cancellation, `.done`, interim assistant events, and replay de-duplication remain correct.
- Long Markdown remains scrollable and cancellable on a simulator and a physical device where available.
- Following the latest message remains smooth; manually scrolling away is respected.
- Settled transcript rows do not re-render solely because the active streaming tail changed.
- Tests cover plain Markdown, code, tables, math, tool output, and a large transcript.
- Full XCTest passes on macOS/Xcode.
- No new third-party dependency, API change, or upstream `hermes-webui` change.

## Validation limitation for this draft

The initial analysis was performed on Linux. No compilation, XCTest, simulator, Instruments, or device run was possible here because the required Apple toolchain is unavailable. Consequently, this draft must remain explicitly unverified until CI and a macOS/Xcode maintainer environment provide build/test/runtime evidence.

## Related work

- #32 — eager transcript rows / long-conversation scrolling.
- #33 — open lazy transcript row PR.
- #103 — historical `ScrollView + VStack` lag report.
- #134 and PR #137 — transcript opening jitter and size-change anchoring.
- #163 — bounded cache-first transcript loading.
- #260 and PR #261 — settled Markdown re-parsing optimisation.
- #217 — open draft combining several performance changes; it documents unresolved scroll-anchor and scope concerns and should not be assumed safe to merge as-is.
