# 0108. Diff and source viewer drawing

Area: performance

## Typeset only the visible characters of a diff row

`ReviewDiffCanvasView.drawCodeText` draws code text with optional syntax colour runs, split into visual lines of `wrapColumns` characters when the layout wraps. It typesets only what the pass can show: the reachable columns of an unwrapped row, or the visual lines of a wrapped row inside `dirtyRect`, so a minified 400 KB line draws like a short one.

Lives in: `HermesMobile/Features/Workspace/ReviewDiff/ReviewDiffCanvasView+Drawing.swift`

## Cache a diff line's character count

`ReviewDiffLine.columnCount` is `content.count`, counted once: layout and drawing ask for it on every frame, and a minified line can run to hundreds of thousands of characters.

Lives in: `HermesMobile/Features/Workspace/ReviewDiff/ReviewDiffRow.swift`

## Detect replaced diff rows by version, not by comparing rows

The host bumps `ReviewDiffSurface`'s `rowsVersion` whenever `rows` is replaced, so the bridge never compares thousands of rows to notice a change.

Lives in: `HermesMobile/Features/Workspace/ReviewDiff/ReviewDiffSurface.swift`

## Keep the viewport report free of observed mutations

The surface calls `visibleRowRangeChanged(_:)` as the viewport moves, including mid-layout. `ReviewDiffHighlightModel` and `SourceFileViewModel` change only bookkeeping the view does not observe synchronously, so a report made mid-layout is safe.

Lives in: `HermesMobile/Features/Workspace/ReviewDiff/ReviewDiffHighlightModel.swift`, `HermesMobile/Features/Workspace/SourceViewer/SourceFileViewModel.swift`
