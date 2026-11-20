# 0158. Hosted UI tests

Area: testing

## Bracket test scroll writes with drag callbacks

Hosted tests move a SwiftUI scroll view the way a finger would: `drag(_:to:)` calls `scrollViewWillBeginDragging`, then `setContentOffset`, then `scrollViewDidEndDragging` on the scroll view's delegate. iOS 27 restores its own tracked position over a bare offset write on the next layout, so the write is bracketed with the drag callbacks SwiftUI listens for.

Lives in: `HermesMobileTests/BotChatPresentationTests.swift`

## Test split-view visibility as policy, not hosted

`testRoomySplitKeepsItsSidebarOutUnlessTheUserCollapsedIt` pins the visibility policy the split view applies on a root selection or width change by asserting `NavigationSplitViewVisibility.settled(isRoomy:isCollapsedByUser:)` directly. The portrait close is not hosted: UISplitViewController's display-mode change did not settle reliably on CI's parallel test clones, and a collapsed sidebar can't be told apart from `.automatic` in an iPhone-idiom host anyway.

Lives in: `HermesMobileTests/SessionNavigationStateTests.swift`

## Keep hosted-chat test cache alive for the process

The app owns its cache for the scene's lifetime. A hosted chat's initial attach can finish after its window closes, so `SessionNavigationStateTests` keeps its in-memory `ModelContainer` in a static `selectionCache` with the same process lifetime instead of invalidating a context still in use.

Lives in: `HermesMobileTests/SessionNavigationStateTests.swift`

## Test inline rendering with a phone-sized stack

`InlineElementStackDepthTests` renders one overlong paragraph with only an iPhone's 1 MB main-thread stack left. The simulator's main thread has 8 MB, which hides the stack overflow in #1333, so a plain render in tests would not catch it.

Lives in: `HermesMobileTests/MarkdownMathRendererTests.swift`
