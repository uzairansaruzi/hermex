# Long streaming assistant messages: performance investigation

> **Status:** implementation slice and follow-up performance design for issue [#291](https://github.com/uzairansaruzi/hermex/issues/291)
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

## Implemented in this PR

This PR now includes the first low-risk runtime slice in addition to the design analysis:

- `ChatViewModel.appendAssistantToken` no longer constructs flushed + pending replay content on ordinary streams; that work is restricted to reconnect replay connections.
- `ChatViewModel.appendReasoning` applies the same normal-path bypass.
- `ChatViewModelStreamingPaceTests` adds a large normal-stream fixture and verifies assistant and reasoning content byte-for-byte.

The incremental Markdown render-state design below remains a follow-up slice. It is intentionally not implemented without macOS/Xcode profiling and compilation.

## Concrete improvement analysis

### 1. First low-risk change: do not build replay state on the normal stream path

The current token path constructs `flushedContent + pendingAssistantTokenChunks.joined()` before calling `deduplicatedReplayToken`, even when the connection is **not** a replay connection. The de-duplication helper immediately returns the input in that normal case, so the full effective-content string is unnecessary work for every ordinary token.

The same pattern exists for reasoning chunks: `appendReasoning` joins pending reasoning chunks before calling `deduplicatedReplayText`, although the helper returns the input immediately when replay mode is inactive.

A focused first implementation should:

- append directly to the pending token buffer on the normal connection path;
- append directly to the pending reasoning buffer on the normal connection path;
- perform effective-content construction only while replay de-duplication is actually enabled;
- keep the existing full replay algorithm unchanged initially;
- add tests proving normal streams and replay streams produce identical final bytes.

This is preferable to changing replay matching and buffering simultaneously. It removes avoidable work from the common path while keeping the most delicate recovery behavior stable.

### 2. Second low-risk change: move repeated state lookup out of every token

`appendAssistantToken` also searches `messages` for the streaming assistant message on every token. The message ID is already established by `ensureStreamingAssistantMessage()` and the visible message is only mutated during flushes and explicit event paths.

A safe design should either:

- resolve the message index once per flush, not once per token; or
- add a stream-scoped index/cache that is invalidated whenever a reload, snapshot merge, prepend, or completed-session reconciliation can reorder or replace `messages`.

The first option has less correctness risk. It avoids introducing stale-index bugs while still removing the lookup from the hot append path.

### 3. Replace whole-document streaming scans with an append-only render state

The current streaming renderer has several whole-string scans per update:

1. `MarkdownContentRenderingPolicy.fallbackReason(for:)` checks character and line limits;
2. `MarkdownMathLayoutCache.uncachedLayout(for:)` segments the complete displayed string;
3. `StreamingMarkdownBlockSplitter.split(content)` scans every line and recreates stable chunk strings;
4. `StreamingTextFadeTailSplitter.split(...)` scans the active Markdown again;
5. `advanceFadeWindow` splits both the old and new content again before comparing prefixes;
6. MarkdownUI lays out the changing active content.

For an append-only normal stream, the renderer should own an incremental value model, for example `StreamingMarkdownRenderState`, containing:

- immutable stable chunks with stable IDs;
- the current active Markdown tail;
- fence/list/block state needed to recognise the next stable boundary;
- incremental character and line counts;
- a stream generation/revision for replacement events;
- the small fade-window state for the active tail.

On an ordinary append, scan only the newly appended suffix plus the unfinished boundary line. Once a chunk is sealed, never pass it through the streaming splitter again. On a replacement, replay mismatch, interim replacement, snapshot restore, or non-prefix update, reset the state and rebuild from the new complete content. Correctness is more important than forcing every update through the incremental path.

The SwiftUI shape should be:

```text
raw stream content
        │
        ├─ normal append ──► append to StreamingMarkdownRenderState
        │                         ├─ stable chunks (unchanged IDs/content)
        │                         └─ active tail (the only changing view)
        │
        └─ replacement/reset ─► rebuild state and increment generation
```

`StreamingMarkdownRenderer` should render the state rather than calculate `segments` from the complete string in `body`. `StreamingMarkdownChunkedView` should receive the stable chunks and active tail as values. A generation ID must invalidate SwiftUI state when the stream is reset so old fade stores cannot be reused for unrelated content.

### 4. Make the large-content fallback incremental too

The current streaming body repeatedly calls `content.count`, trims the content, and counts lines through `MarkdownContentRenderingPolicy`. For large Swift `String` values these checks are themselves non-constant work.

The incremental render state should maintain:

- `characterCount` or the exact threshold state;
- `lineCount` or the exact threshold state;
- `hasVisibleContent`.

The fallback decision can then be made from metadata. The final/static renderer can continue to use the existing policy and cache. The thresholds must remain unchanged unless a product decision explicitly changes them.

### 5. Keep stable Markdown and fade rendering separate

The current implementation correctly tries to avoid re-rendering old chunks, but the parent still recomputes the split model on every body evaluation. The improved design should make that optimisation real:

- stable chunks use stable IDs and `isStreaming: false`;
- only the active tail uses `isStreaming: true`;
- the fade timeline is mounted only for the active fade window;
- settled chunks are not included in the changing `TimelineView` input;
- a chunk is not copied into a new `String` merely because another token arrived.

Do not cache each token-sized string in `MarkdownMathLayoutCache`: that would churn the cache and evict settled layouts. Cache or retain only sealed chunks and use the existing static layout cache for those chunks where appropriate.

### 6. Scope transcript invalidation to the active row

`ChatTranscriptMessageBlock` is already `Equatable`, but its equality compares the complete `reasoningGroups` array for every row. `ChatView` also supplies `viewModel.displayedReasoningGroups` at the transcript root on every body pass.

After measuring this path, a follow-up should pre-index reasoning groups by anchor and pass each row only its own groups. The same principle applies to tool groups and live state: unrelated rows should receive stable empty/nil values and should not compare against changing arrays owned by the active row.

This is a secondary optimisation. It should not be mixed into the first token-buffer change unless profiling shows it is a dominant cost.

### 7. Treat lazy transcript rows as a separate slice

Changing `VStack` to `LazyVStack` is still the right direction for many-message transcripts, but it is not a substitute for fixing one huge active message. It belongs to #32/#33 because it has separate risks:

- initial scroll-to-bottom targeting an unrealised row;
- preserving the visible row after loading older messages;
- `.defaultScrollAnchor(..., for: .sizeChanges)` behavior while Markdown height settles;
- interaction with the existing `ChatPrependScrollPositionController`.

Do not merge the lazy-row change with a streaming parser rewrite or a page-size reduction. Each slice should have an isolated benchmark and regression coverage.

## Recommended implementation order

1. **Measure** the current path with signposts around token append, buffer drain, fallback checks, splitter calls, `uncachedLayout`, and scroll-trigger handling.
2. **Add tests** for a pure append-only render state: stable chunks, active tail, prefix append, reset, fence boundaries, lists, math, and byte-identical reconstruction.
3. **Remove normal-path replay work** from `appendAssistantToken` and `appendReasoning`; keep replay behavior unchanged and test both branches.
4. **Avoid per-token message lookup** by resolving the row at flush time, with explicit invalidation on reload/snapshot/reconciliation.
5. **Introduce incremental streaming Markdown state** and compare its reconstructed output against the current splitter on generated fixtures.
6. **Optimise active-row invalidation** only if Instruments shows it is material.
7. **Land lazy transcript rows separately** under #32/#33.
8. **Run full XCTest, Instruments, and signed simulator/manual validation** before marking the implementation PR ready.

## What should not be done

- Do not simply increase the 16 ms or 48 ms pacing intervals: that hides work and makes the displayed answer fall further behind.
- Do not put every partial string into `NSCache`: it creates cache churn and memory pressure.
- Do not remove Markdown, code highlighting, math, fade animation, or scroll anchoring without measuring the user-visible regression.
- Do not use `LazyVStack` alone as evidence that the single-message streaming path is fixed.
- Do not change replay de-duplication semantics without fixtures for prefix, suffix, overlap, awkward Unicode boundaries, and reconnect replay.
- Do not claim a performance win from source inspection; the win must be demonstrated with macOS/Xcode measurements.

## Acceptance criteria

- Final assistant content is byte-for-byte identical to the server content for normal streams and replay/reconnect streams.
- Cancellation, `.done`, interim assistant events, and replay de-duplication remain correct.
- Long Markdown remains scrollable and cancellable on a simulator and a physical device where available.
- Following the latest message remains smooth; manually scrolling away is respected.
- Settled transcript rows do not re-render solely because the active streaming tail changed.
- Tests cover plain Markdown, code, tables, math, tool output, and a large transcript.
- Full XCTest passes on macOS/Xcode.
- No new third-party dependency, API change, or upstream `hermes-webui` change.

## Validation limitation

The initial analysis and implementation were performed on Linux. No compilation, XCTest, simulator, Instruments, or device run was possible here because the required Apple toolchain is unavailable. The focused runtime slice is therefore ready for maintainer review but still requires CI and macOS/Xcode build, test, and runtime evidence before merge.

## Related work

- #32 — eager transcript rows / long-conversation scrolling.
- #33 — open lazy transcript row PR.
- #103 — historical `ScrollView + VStack` lag report.
- #134 and PR #137 — transcript opening jitter and size-change anchoring.
- #163 — bounded cache-first transcript loading.
- #260 and PR #261 — settled Markdown re-parsing optimisation.
- #217 — open draft combining several performance changes; it documents unresolved scroll-anchor and scope concerns and should not be assumed safe to merge as-is.
