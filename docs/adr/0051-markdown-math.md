# 0051. Markdown math

Area: chat-transcript

## Give inline math images a nonempty alt

`MarkdownMathFormatter.inlineMathImages` emits each inline math image with a nonempty alt (`\u{FFFC}`), because Foundation drops an image with an empty alt inside a link.

Lives in: `HermesMobile/Features/Chat/MarkdownMathFormatter.swift`

## Never open inline math on a dollar followed by a digit or whitespace

`$` followed by a digit or whitespace is currency or prose, not math. Two bare amounts on one line used to pair into an inline-math span and TeX-render the prose between them, with hyphenated words like "pay-in-arrears" qualifying through the operator heuristic. `MarkdownMathFormatter` mirrors hermes-webui's inline-math boundary guard, so amounts like "$250" or "$5 and $10" never open a span that swallows the text up to the next `$` on the line.

Lives in: `HermesMobile/Features/Chat/MarkdownMathFormatter.swift`, `HermesMobileTests/MarkdownMathRendererTests.swift`

## Never close inline math on a dollar after whitespace

`MarkdownMathFormatter` reads whitespace directly before a `$` as a prose boundary, not the close of a math span. This matches hermes-webui, KaTeX auto-render, and markdown-it-katex.

Lives in: `HermesMobile/Features/Chat/MarkdownMathFormatter.swift`

## Reject $$ pairs that read as prose

`$$` is also the shell's PID: `$$ and $$` is prose, `$$42$$` is math. `MarkdownMathSegmenter` leaves a `$$` pair whose body reads as prose (whitespace, and failing `MarkdownMathFormatter.looksLikeMath`) literal, and the rejected pair's closer never opens a later span.

Lives in: `HermesMobile/Features/Chat/MarkdownMathSegmenter.swift`

## Fall back to the whole-string math pass when display delimiters yield no math

When the segments hold no math, `MarkdownMathLayoutCache` reuses the markdown the segmenter already produced; it is already inline-math-formatted, so re-running that pass would be a second full-string walk for an identical result. The exception: the segmenter recognizes but drops a display span whose body is empty or whitespace-only (`$$$$`, `\[ \]`), so there is no `.displayMath` segment, yet the surrounding markdown no longer holds the delimiters, and joining it would silently swallow literal text the old single-pass renderer preserved. Counting segments is not enough, since an empty span at the very start still leaves one markdown segment, so `containsDisplayDelimiter` asks whether the content has a display delimiter at all and, if it does, defers to the legacy whole-string pass. That costs an extra walk only for the rare content carrying a display delimiter that produced no math; it is deliberately conservative, since a false positive costs one pass and a false negative drops text.

Lives in: `HermesMobile/Features/Chat/MarkdownMathSegmenter.swift`
