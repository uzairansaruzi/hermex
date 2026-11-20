# 0052. Markdown reply rendering

Area: chat-transcript

## Hide drawable-fence controls anywhere inside a streaming reply

The `markdownReplyIsStreaming` environment value is true inside a streaming reply, sealed chunks included. Sealed chunks render with `isStreaming: false` to get highlighting, but the reply swaps to its settled view when it ends, so a control there (a drawable fence's View button) would vanish mid-use. The control is gated on this flag, not on `isStreaming`.

Lives in: `HermesMobile/Features/Chat/MarkdownRenderer.swift`

## Force code blocks left to right

Code and diff blocks apply `.forcedLeftToRight()` so they never mirror inside an RTL message (#259): the language header, the copy and wrap controls, and the source itself stay LTR. `DrawableFenceViewButton`'s sheet inherits that forced direction, so it sets `layoutDirection` from `UIApplication.shared.userInterfaceLayoutDirection` to follow the app again.

Lives in: `HermesMobile/Features/Chat/MarkdownRenderer.swift`

## Cap inline elements per markdown paragraph

MarkdownUI joins a paragraph's inline elements with `Text` `+`, which SwiftUI resolves recursively; about 600 overflow an iPhone's 1 MB main-thread stack (#1333). `MarkdownContentRenderingPolicy.maxInlineElementsPerParagraph` is 300, and a paragraph over it (`hasTooManyInlineElements`) renders as one `Text`.

Lives in: `HermesMobile/Features/Chat/MarkdownRenderer.swift`

## Content-address the code highlight cache

`MarkdownCodeHighlighter` keeps its highlights in an `NSCache` marked `nonisolated(unsafe)`: `NSCache` is thread-safe, which is what lets the main actor peek it synchronously through `cachedHighlight(for:)`. The cache is content-addressed, so a hit needs the code itself and entries never reveal one server's transcript under another.

Lives in: `HermesMobile/Features/Chat/MarkdownRenderer.swift`

## Measure markdown table cells at their clamped width

`Grid` sizes table rows from each cell's ideal size. A plain `.frame(maxWidth:)` caps the ideal width but still reports the single-line ideal height, so long cell text wrapped at render time without the row growing and rows overlapped (#233). `TableCellWidthCap` is a single-child `Layout` that caps the cell's width and reports the height the content needs at that capped width, so the reported height matches what is drawn.

Lives in: `HermesMobile/Features/Chat/MarkdownRenderer.swift`

## Never sum diff hunk counts

`MarkdownDiffFormatter` compares and decrements `@@` hunk counts but never sums them, so a header like `-1,9223372036854775807` cannot overflow.

Lives in: `HermesMobile/Features/Chat/MarkdownDiffCodeBlock.swift`

## Keep the response selection adapter out of the accessibility tree

`UITextInteraction` promotes a `UITextInput` to an accessibility element. `ResponseSelectionInput` is only a container adapter, so it reports `isAccessibilityElement` as false and VoiceOver reaches the hosted text and controls instead.

Lives in: `HermesMobile/Features/Chat/ResponseSelectionInput.swift`

## Forward every environment value hosted replies read

`ResponseTextSelection` hosts reply content in its own SwiftUI graph, which sees only the values in `ResponseSelectionEnvironment` plus UIKit traits. A renderer that reads another environment value must join `ResponseSelectionEnvironment`, or a settled reply keeps the old value until its text changes.

Lives in: `HermesMobile/Features/Chat/ResponseTextSelection.swift`

## Track hosted reply height as state

`ResponseTextSelection` keeps the hosted content's height as state and reads it in `updateUIViewController`. The content can grow after its first layout (MarkdownUI block margins, async code highlighting); reading the height there turns that growth into an update, so SwiftUI asks `sizeThatFits` again instead of keeping a stale height that lets the reply spill under the rows above and below it.

Lives in: `HermesMobile/Features/Chat/ResponseTextSelection.swift`
