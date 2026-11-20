# 0114. Session list invalidation

Area: performance

## Accept a pending link only when one is set

A link arriving while a chat, screen or sheet covers the rows pops and closes them, so what it opens or says shows on `HermesSessionListView`. The view calls `covers.accept(pendingLink, on:)` only when `pendingLink` is non-nil: `covers` is observed, and its setter runs for any mutating call.

Lives in: `HermesMobile/Features/SessionList/HermesSessionListView.swift`

## Isolate the status filter section's observation

`HermesStatusFilterSection` (the Filter menu's status choices and Mark All as Read) is its own view, so reading the unread marks to count the chats in scope invalidates only that section, not the list's body.

Lives in: `HermesMobile/Features/SessionList/HermesSessionListView.swift`

## Reassign session attention states only on real change

`SessionListViewModel.attentionStatesBySessionID` is refreshed on the same tick that already checks stream liveness. Only sessions with an active stream ever have an entry, and the map is reassigned only when a value actually changes so rows do not invalidate on every poll tick.

Lives in: `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Leave out-of-range chat shortcuts enabled instead of counting rows

The View menu's Next and Previous Chat commands sit beside Toggle Sidebar, and ⌘⇧] and ⌘⇧[ back up ⌃Tab in case iPadOS or a focused text view takes it first. Out-of-range positions do nothing rather than grey out: counting rows in the commands would filter and sort every session on each update.

Lives in: `HermesMobile/HermesMobileApp.swift`
