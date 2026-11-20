# 0176. Git diff view

Area: workspace-git

## Stop diff highlighting only when the sheet is dismissed

`GitDiffView` attaches its `onDisappear`, which cancels the refresh and the highlights, to the sheet's root view. That way only dismissal stops syntax colour, not a screen pushed inside the sheet.

Lives in: `HermesMobile/Features/Workspace/GitDiffView.swift`

## Reset diff highlights on every refresh

`ReviewDiffRow` ids are stable within one load, but a refresh can reuse an id for different text. `ReviewDiffHighlightModel` remembers the rows already sent, coloured or not, so `GitDiffView.refresh()` calls `highlights.reset()` first and colour starts over; otherwise old colour would land on new lines.

Lives in: `HermesMobile/Features/Workspace/GitDiffView.swift`, `HermesMobile/Features/Workspace/ReviewDiff/ReviewDiffHighlightModel.swift`

## Treat a stale accessibility row index as an empty row

VoiceOver can hold an accessibility element from before a rows rebuild. So every `ReviewDiffCanvasView` accessibility accessor treats an out-of-range row index as an empty row instead of trapping.

Lives in: `HermesMobile/Features/Workspace/ReviewDiff/ReviewDiffCanvasView+Accessibility.swift`

## Measure drawn diff columns past the monospaced grid

`ReviewDiffCanvasView.drawnCodeColumns(for:)` counts the characters of an unwrapped line that drawing typesets. It starts at `reachableCodeColumns` and doubles while that prefix renders narrower than the reach, because glyphs narrower than the grid (zero-width characters, proportional fallback fonts) put more characters on screen than the grid predicts.

Lives in: `HermesMobile/Features/Workspace/ReviewDiff/ReviewDiffCanvasView.swift`

## Store a review comment's line numbers as a pair, not a range

`ReviewCommentContext.lines` holds the first and last display line numbers in row order, or nil when no line has one. It is not a range, because a diff selection can run from a higher old-side number to a lower new-side one.

Lives in: `HermesMobile/Features/Workspace/ReviewDiff/ReviewDiffSelection.swift`
