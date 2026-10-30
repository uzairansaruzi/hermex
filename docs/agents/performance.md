# Performance: invariants and their guards

The rules behind the "Performance without compromise" pillar, each with what enforces
it today. Guards named here are test classes in `HermesMobileTests/` or signposts;
where nothing automated exists, the row says **review only** so the gap stays visible.
Symbols are linked, never copied numbers, so this page cannot drift from the code.

## Invariants

| Invariant | Where it lives | Guard |
|---|---|---|
| Settled transcript rows skip re-evaluation while a reply streams: live-stream inputs are scoped to the anchor row, and rows compare by value | `ChatTranscriptView` (live-input scoping in `displayedTranscriptMessages` row construction, `.equatable()` wrapper, `ChatTranscriptMessageBlock.==`) | Partial: `ChatTranscriptEnvironmentStabilityTests` pins that environment closures don't invalidate skipped rows. **No test pins the row skip itself**; #1405 adds a render-budget guard when it merges. |
| The Sessions transcript uses an eager stack (#32); initial/history requests are paged, but loaded pages accumulate | `ChatTranscriptView`; page size `HermesREST.transcriptPageSize` | The page size is not a cap on rendered rows: `ChatViewModel.loadOlderMessages` prepends to the existing array. No automated total-row bound exists; do not document one. |
| A Bot room draws only its newest page of events | `BotRoomTranscriptWindow` (`BotRoomView`); rules in `docs/agents/bots.md` | `BotChatPresentationTests.testWarmRoomBuildsOnlyTheNewestPageOfReplies`, `BotRoomTests` |
| Streamed text reveals on a tick, not per token; completion flushes immediately | `ChatViewModel` reveal tick and `flushPendingStreamingContent()` | `ChatViewModelStreamingPaceTests` |
| Only the streaming tail re-parses: settled markdown seals into stable chunks | `StreamingMarkdownBlockSplitter.stableChunkTargetUTF8Count` | `StreamingMarkdownSupportTests`; `scripts/benchmark-streaming-scans` |
| Transcript images: one load per key, decoded off main, capped at a fixed pixel size, purged on memory warning, bounded in decoded bytes and image count, server-namespaced | `TranscriptImageCache` | `TranscriptImageCacheTests` (single-flight, memory warning, pixel cap). The byte and count limits themselves are not asserted. |
| The diff canvas draws only visible rows (plus a four-row overscan); rows are never views | `ReviewDiffCanvasView` and `ReviewDiffCanvasView+Drawing` | Partial: `ReviewDiffCanvasViewTests` guards width measurement, not viewport-only drawing; the `reviewDiffSignposter` intervals make regressions measurable |
| SwiftData newest reads are fetch-limited | `CacheStore` and `CacheStore+Hermes` fetch descriptors | `Cache Read` / `Cache Write` signposts; `CacheStoreTests` covers correctness, not the limit |
| Held live frames during a Hermes attach are bounded by `HermesConversation.heldFrameLimit` | `HermesConversation.heldFrameLimit` | `HermesConversationTests` (flood test). The gateway's own replay ring (`tui_gateway/event_replay.py`, pinned in `UPSTREAM_TESTED_SHA`) holds a comparable bounded count; its byte limits can evict earlier. |
| Signposts carry static names and integer metadata only | `PerformanceSignposts` | **Review only** |
| Launch paints cached rows first | `LaunchSignpost` (`PerformanceSignposts`) | `scripts/benchmark-sim-launch` |
| Debug instruments compile out of Release | `HitchMeter` (`#if DEBUG`) | `HitchMeterTests` (logic only) |
| No continuously repainting animation; every animation respects Reduce Motion | `AGENTS.md` § Taste | **Review only.** `repeatForever` has zero uses in the app targets today. |

## How to measure

Release build for timings; Debug is fine for counts. Take a median of three or more
runs, interleave the builds, and compare against the same base —
`scripts/benchmark-sim-launch` is the worked example. Signposts and their reading
commands live in `DEVELOPMENT.md` § Launch arguments and profiling; link there
instead of duplicating them.

## Before you change the transcript

- Keep new row inputs `Equatable` and add them to `ChatTranscriptMessageBlock.==`.
- Pass app-wide values to rows only if a stream tick doesn't change them.
- Visibility gating is a proposed rule from #1370, not a current guarantee until
  that change lands.
