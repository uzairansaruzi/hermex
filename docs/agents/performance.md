# Performance — agent notes

"Performance without compromise" is a product pillar (`AGENTS.md`). This page
lists the rules the code keeps today and what catches a change that breaks
each one. Numbers live in the code: the table names the symbol that holds a
limit, so read the value there.

## Invariants

| Invariant | Lives in | Guard |
|---|---|---|
| Settled transcript rows skip re-evaluation while a reply streams: live-stream inputs reach only the anchor or streaming row, and rows compare by value | `ChatTranscriptView.transcriptScrollContent`, `.equatable()` on each `ChatTranscriptMessageBlock`, `ChatTranscriptMessageBlock.==` | `ChatTranscriptRenderBudgetTests` (zero settled-row body evaluations across text-only reveal ticks, counted by `RenderProbe`; local only, since PR CI skips it until #1516); `ChatTranscriptEnvironmentStabilityTests` (environment closures don't invalidate skipped rows) |
| A text-only stream tick doesn't re-derive transcript structure: it patches the reply's row, and the chat reuses its turn folds and end-of-turn rows until `transcriptStructureRevision` or another memo input changes (#1417). Reasoning, a first visible reply, and every non-text change take the full path | `ChatViewModel.replaceStreamingReply(at:with:)`, `ChatViewModel.transcriptStructureRevision`, `TranscriptStructureMemo` | `ChatViewModelStreamingPaceTests` (`testTextOnlyTicksPatchTheReplyWithoutReDerivingTheTranscript`, `testATickThatCompletesInTextReasoningReDerivesTheTranscript`). The memo's inputs are review only. |
| Transcript media loads only once it scrolls into view, and an admitted load is never cancelled by scrolling away (#1370) | `View.loadsOnceVisible(id:admit:)` on images, MEDIA probes, audio, and link previews | `TranscriptMediaVisibilityTests`, `ResponseSelectionVisibilityTests`. Link previews are gated but untested: `LPMetadataProvider` has no loader seam. |
| The Sessions transcript is an eager `VStack` (#32). Hermes history arrives in pages, but loaded pages accumulate | `ChatTranscriptView.transcriptScrollContent`; page size `HermesREST.transcriptPageSize`; `ChatViewModel.loadOlderMessages` prepends | **None.** The page size is not a cap on rendered rows, and no total-row bound exists. Don't document or assume one. |
| A Bot room opens building only its newest page of events; load earlier, a search jump, and later live events widen the anchored window | `BotRoomTranscriptWindow.pageSize` (`docs/agents/bots.md`) | `BotChatPresentationTests.testWarmRoomBuildsOnlyTheNewestPageOfReplies`, `BotRoomTranscriptWindowTests` |
| Streamed text reveals on a tick, not per token; completion, cancel, error, interim reply, and snapshot flush at once | `ChatViewModel.revealStreamingContentTick()`, `ChatViewModel.flushPendingStreamingContent()` | `ChatViewModelStreamingPaceTests`; `Stream Batch Apply` signpost (`forced=0` / `forced=1`) |
| Only the streaming tail re-parses: settled reply markdown seals into stable chunks, and streaming reasoning keeps a bounded active tail | `StreamingMarkdownBlockSplitter.stableChunkTargetUTF8Count`; `StreamingReasoningTextState.maximumActiveTailCharacterCount` | `StreamingMarkdownBlockSplitterTests` (`testStableChunkThresholdCountsUTF8Bytes`), `StreamingReasoningTextStateTests` (`testLargePrefixStreamReconstructsExactlyAndPreservesStableChunks`); `scripts/benchmark-streaming-scans`; `Markdown Parse` signpost |
| Transcript images: one load per key, decoded off main, capped at `ImagePreviewDownsampler.attachmentMaxPixelSize`, emptied on a memory warning, bounded in bytes and count, keyed by server and session | `TranscriptImageCache` (limits are literals in its `init`) | `TranscriptImageCacheTests` (single flight, memory warning, pixel cap). The byte and count limits are not asserted. |
| The diff canvas draws only the rows in the viewport plus a four-row overscan; rows are never views | `ReviewDiffCanvasView`, `ReviewDiffCanvasView+Drawing` | Partial: `ReviewDiffCanvasViewTests.testDrawnColumnsGrowPastZeroWidthCharactersAndAreMeasuredOncePerRow` guards width measurement, not viewport-only drawing; `reviewDiffSignposter` intervals `Draw`, `RebuildLayout`, `HighlightDiffRows` |
| SwiftData reads of the newest cached messages are fetch-limited | `CacheStore.cachedMessages(limit:)`, `CacheStore.cachedHermesMessages(limit:)` | `Cache Read` / `Cache Write` signposts (`rows=`). `CacheStoreTests` covers correctness, not the limit. |
| Live frames held during a Hermes attach are bounded, matching the host's per-session replay ring | `HermesConversation.heldFrameLimit` | `HermesConversationTests` (the flood test past `heldFrameLimit`) |
| Signposts carry static names and integer metadata only | `PerformanceSignposts.swift` header | Review only |
| Launch paints cached rows first, then the host's first page | `LaunchSignpost` | `scripts/benchmark-sim-launch` (`Launch` and `live` medians) |
| Debug instruments compile out of Release | `HitchMeter` (`#if DEBUG`), `RenderProbe` (Release `hit` is an empty inlined stub) | `HitchMeterTests` covers the hitch math only; the Release compile-out is review only |
| No continuously repainting animation; every animation respects Reduce Motion | `AGENTS.md` § Taste | Review only. `repeatForever` has zero uses in `HermesMobile/` today. One owner-approved exception: the Thinking slider in Model settings and its Settings picker (`ThinkingSliderTrack`, #1550) repaint at up to 60 fps while on screen, and only there. Reduce Motion stills them. |

## Guards

A guard is a test class that fails when the invariant breaks, or a signpost
that makes the cost visible in Instruments. A signpost shows a regression; only
a test stops one. Put a new budget (a render count, a request count, a row
limit) in a test so a regression fails locally, and add its row here.

"None" and "review only" are deliberate: they mark the gaps. Today those are
the eager transcript's total row count, the image cache's byte and count
limits, viewport-only diff drawing, the cache fetch limit, link-preview
gating, signpost privacy, the Release compile-out, and animations.

## How to measure

- Time Release builds (Product → Profile). Debug is fine for counts, such as
  `RenderProbe` totals or request counts.
- Report a median of three or more runs. Interleave the builds you compare on
  one simulator from the same base, as `scripts/benchmark-sim-launch` does, so
  warmup and network drift favor neither.
- Signpost names, metadata, and the `xctrace` record and export commands live
  in `DEVELOPMENT.md` § Launch arguments and profiling; reading `RenderProbe`
  by hand is under § Counting transcript renders there.

## Before you change the transcript

1. Make every new `ChatTranscriptMessageBlock` input `Equatable` and add it to
   `==`. A closure may stay out of `==` only if it is a pure function of values
   that are compared.
2. Pass a value to every row only if a stream tick doesn't change it. Scope live
   values to the anchor or streaming row, as `transcriptScrollContent` does.
3. Load new media or network content in a row through `loadsOnceVisible(id:admit:)`,
   never at mount.
4. Give turn folds or end-of-turn rows a new input only through
   `TranscriptStructureMemo.Inputs`. If reply text starts to affect transcript
   structure, exclude that case from `ChatViewModel.textOnlyTranscriptRow`.

Then run `ChatTranscriptRenderBudgetTests` and
`ChatTranscriptEnvironmentStabilityTests`.
