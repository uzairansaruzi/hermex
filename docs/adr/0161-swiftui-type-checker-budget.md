# 0161. SwiftUI type-checker budget

Area: ui

## Split large view builders so the CI type-checker finishes

Long SwiftUI builders exceed the Swift type-checker's time budget on the CI toolchain. `BotsInboxView` keeps its rows, its presentations, and each row in separate expressions: `attachPresentations` carries the sheets, dialogs, navigation destinations and open/close lifecycle split from `body`, and `roomRow` is its own function with the pinned and hidden flags read once, because inlined in the list builder the row's menus and swipe actions were too much. `SessionListView.routedNavigationContainer` holds the navigation container plus bot-link routing off `body`'s modifier chain, which is already long enough that adding to it exceeds the budget. Folding these back into `body` breaks the CI build.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`, `HermesMobile/Features/SessionList/SessionListView.swift`
