# 0110. Math rendering

Area: performance

## Memoize math layout by content string

`MarkdownMathLayoutCache` memoizes the math-segmentation pass, which is pure over its input string. `segments(in:)` walks the whole string twice (once to build the protection mask, once to scan), and the no-math branch then ran `inlineMathImages` over the whole string again; measured with `-O`, an 8 KB assistant answer cost ~7.5 ms per call. SwiftUI re-evaluates a body for reasons unrelated to the text (a sibling fold toggling, a scroll-position flip, a `@AppStorage` write), so that cost was paid repeatedly for a string that never changed, while a cache hit is ~0.0001 ms. It is keyed by the exact content string and uses `NSCache` so entries evict under memory pressure rather than growing with transcript length, and because it is thread-safe, which matters since SwiftUI may evaluate bodies off the main thread.

Lives in: `HermesMobile/Features/Chat/MarkdownMathSegmenter.swift`

## Memoize LaTeX renderability

Renderability (`MathLaTeX.isRenderable`) is a pure, deterministic function of the trimmed LaTeX string, so it is memoized. `DisplayMathView` and `MathFenceOrCodeBlock` re-check on every layout pass, and markdown-ui rebuilds code blocks on each streaming chunk, so without the cache the same expression is parsed many times over. `NSCache` is thread-safe and self-evicts under memory pressure.

Lives in: `HermesMobile/Features/Chat/DisplayMathView.swift`

## Read the inline math image cache without hopping through the actor

`InlineMathImageCache` reads its `NSCache` storage directly, since `NSCache` is thread-safe. Warm reads must not hop through the actor and publish another view update on each token; only cold rendering is isolated.

Lives in: `HermesMobile/Features/Chat/DisplayMathView.swift`

## Concatenate inline math prose into one Text

Prose runs between inline math share one `Text`, because a `+` per run nests as deep as the paragraph is long.

Lives in: `HermesMobile/Features/Chat/DisplayMathView.swift`
