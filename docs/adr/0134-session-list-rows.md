# 0134. Session list sidebar and rows

Area: sessions

## Use checked Toggles, not a menu Picker, for Profile choices

The Hermes session list shows every Profile's sessions, each row tagged with its Profile (#709), or one Profile's. Picking a Profile lists it and makes it the server's pick, which the composer's Profile chip shares (#1015); All Profiles keeps the pick for New Session. The choices are checked toggles rather than a `Picker`, because a menu `Picker` shows only an option's first line and drops the model (#1679).

Lives in: `HermesMobile/Features/SessionList/HermesSessionListView.swift`

## Offer no mutations on a bot's Bot Chat row

Rows normally offer pin, rename, move, archive and delete. A bot's Bot Chat, which a Hermes search lists (#1053), belongs to its bot and offers none of them: pinning would also unhide it, and renaming orphans it.

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Keep Archive as the edge-most trailing swipe action

Archive stays the first button in `sessionTrailingSwipeActions`, because a full swipe commits the edge-most button. Reordering the buttons changes what a full swipe does.

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Suppress the avatar server switcher while search is expanded

A long press on the header avatar switches the active server, reusing #17's switch and add actions; a `contextMenu` adds the long press without stealing the plain tap. The switcher is suppressed while search is expanded so the "close search" tap state is untouched (#283).

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Emit sidebar disclosure subrows as separate List rows

Each sidebar disclosure subrow is its own `List` row, like the session rows below it. `List` does not animate height or transition changes inside a single row, so packing the subrows into one row made expand and collapse snap instantly. As real rows they fold in and out, driven by a value-based `.animation` on the `List` in `SessionListView`, which works even though the disclosure booleans are `@AppStorage`-backed.

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Hide Active Profile disclosure in single-profile mode

In single-profile mode the server rejects switching Profiles, so the whole "Active Profile" disclosure would only no-op or error. It is hidden (#24).

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Keep the add-project button a sibling of the Projects disclosure

The standalone "create empty project" button, shown only while the Projects list is expanded, is a sibling of the disclosure button, not nested inside its label, mirroring the "All" button below it. Nesting it in the label flattened it into the parent's accessibility element and made it unreachable by VoiceOver.

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Disable session-derived attention fallback for cached rows

`SessionRowView` shows what the polling screen resolved or, for screens that do not poll, whatever the session alone can say. That fallback is off while the row shows cached data: a cached summary keeps the `isStreaming`/`activeStreamId` it was captured with, so an offline row would otherwise claim the agent is still working. Cached rows fall back to their relative time instead.

Lives in: `HermesMobile/Features/SessionList/SessionRowView.swift`

## Use wall-clock now inside the per-minute TimelineView

The row's `TimelineView(.everyMinute)` is only the once-a-minute trigger; the label reads `.now`, not `context.date`. `context.date` is the minute's start, so a mid-minute render would read "in 38s".

Lives in: `HermesMobile/Features/SessionList/SessionRowView.swift`

## Keep last known attention state when a probe fails

A failed approval or clarify probe is not evidence that nothing is pending, so `SessionListViewModel` keeps what the last successful tick knew rather than letting the row fall back to "Working". A previous `.approval` masks any clarification, so it carries no clarify knowledge, and a clarify probe that fails behind it resolves to nothing pending.

Lives in: `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Sweep leaked session exports once per process

Exports can leak from a previous run when the view is dismissed while a download is in flight, so the share sheet and its on-dismiss cleanup never appear; `SessionListViewModel` sweeps `exportsRootDirectory` to remove them. `State(initialValue:)` re-runs the init on every parent redraw, so the sweep is a lazy static (`sweepLeakedExportsOnce`) that runs once per process; sweeping on every init would delete a file an active share sheet is presenting. The first init always precedes the first export, so the single sweep can never race an in-flight export.

Lives in: `HermesMobile/Features/SessionList/SessionListViewModel.swift`
