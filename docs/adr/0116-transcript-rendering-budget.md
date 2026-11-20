# 0116. Transcript rendering budget

Area: performance

## Keep settled transcript rows equatable

While a reply streams, a text-only reveal tick re-renders the streaming row and none of the settled rows above it. Settled rows skip their bodies through `ChatTranscriptMessageBlock`'s `.equatable()`. A new non-`Equatable` input, or a value handed to every row, breaks that and makes every row re-render per tick. `ChatTranscriptRenderBudgetTests` counts passes with `RenderProbe`, driving ticks by hand and laying out each one before the next.

Lives in: `HermesMobileTests/ChatTranscriptRenderBudgetTests.swift`

## Include the audio load key in transcript row equality

Transcript rows (`ChatTranscriptMessageBlock`) skip re-rendering while their inputs compare equal, so the attach generation used as the inline audio player's load key must be one of the compared inputs. Leave it out and an unchanged row's player never learns of a new attach generation.

Lives in: `HermesMobileTests/HermesChatAttachmentTests.swift`

## Keep transcript environment closures stable

The transcript's disclosure and link actions reach every row through the environment, and their owners rebuild those closures on each pass (every stream tick and keystroke). Readers behind a skipped boundary (the transcript's `.equatable()` rows) must not be re-evaluated by that, while a tap still runs the latest closure. On iOS 26 with the keyboard up, an `openURL` rewritten by a modifier whose body re-runs each pass re-ran every link reader while the user typed during a stream. `ChatTranscriptEnvironmentStabilityTests` pins both cases.

Lives in: `HermesMobileTests/ChatScrollPolicyTests.swift`

## Keep the composer draft out of ChatView's body

`ChatView` keeps the draft out of its own body so a keystroke never re-runs the transcript derivations. The composer reports each edit for persistence and scans the draft for `@path` references only when a finished one comes or goes. A get/set draft binding (the old wiring) re-runs the owner on every keystroke; `testSessionsComposerScansFileReferencesWithoutReRunningItsOwnerPerKeystroke` fails on its pass count.

Lives in: `HermesMobileTests/BotChatPresentationTests.swift`

## Memoize turn folds between body passes

`TranscriptStructureMemo` keeps a chat's turn folds and end-of-turn rows between body passes (#1417). Both walk the whole loaded history, and a text-only reveal tick re-renders the chat without changing either, so they are derived again only when `Inputs` change.

Lives in: `HermesMobile/Features/Chat/TranscriptTurnFolding.swift`

## Memoize settled transcript row scans by content

Every assistant bubble scans its text on each body evaluation, and a transcript-wide flag flip (Send, a reply finishing) re-evaluates every row. `TranscriptLinkPreviewEligibility.previewURL` runs `NSDataDetector` over every line of a message that usually has no URL, and `TranscriptMediaSegmentCache` memoizes `TranscriptMediaParser.segments`, which is pure over its content and workspace root; both cache in an `NSCache` (thread-safe, evicts under memory pressure) so a settled row pays once. Streaming rows never preview, so partial text never enters the link cache. Results are a function of the key alone, so entries cannot carry anything from one server to another.

Lives in: `HermesMobile/Features/Chat/TranscriptLinkPreview.swift`, `HermesMobile/Features/Chat/TranscriptMedia.swift`

## Merge selection leaf order as a tree, not arrays

`ResponseSelectionOrder` holds a reply's selectable leaves in view order as a tree. SwiftUI merges these preference values at every level of the reply's tree on every layout, so a merge only links two nodes; concatenating arrays copied every leaf below it each time (#1528).

Lives in: `HermesMobile/Features/Chat/ResponseTextSelection.swift`

## Load inline HTML reports only while visible

`TranscriptHTMLReportView` renders a settled Hermes reply's HTML report in place (#1623). The transcript mounts every row when a chat opens, so nothing downloads until the row is first on screen (`loadsOnceVisible`). The page's height is measured once and locked, up to about three screens, and a taller page fades out at the cap; expand opens it whole. Scrolled away, the page becomes a still image at the same height and its web view is released; coming back loads it again.

Lives in: `HermesMobile/Features/Chat/TranscriptHTMLReportView.swift`

## Never cache streaming math layouts

Streaming text changes on nearly every token, so `MarkdownMathLayoutCache.uncachedLayout(for:)` lays it out without reading or writing the cache. Writing through the cache would insert an entry per token and evict the settled answers the cache exists to protect. The streaming path (`StreamingMarkdownRenderer`) still gets the single-pass benefit: no redundant second `inlineMathImages` walk or full-string `replacingInlineMath` pass, which the no-math branch used to run. `MarkdownMathLayoutCacheTests` guards it.

Lives in: `HermesMobile/Features/Chat/MarkdownMathSegmenter.swift`, `HermesMobile/Features/Chat/MarkdownRenderer.swift`, `HermesMobileTests/MarkdownMathLayoutCacheTests.swift`

## Skip the streaming markdown child on unchanged text

In `StreamingMarkdownRenderer`, `content` changes first and `displayedContent` catches up after the yield, so the first body pass of each update hands the child the text it already drew. `.equatable()` on that child skips its whole-reply work (trim, fallback policy, math layout) on that pass.

Lives in: `HermesMobile/Features/Chat/MarkdownRenderer.swift`
