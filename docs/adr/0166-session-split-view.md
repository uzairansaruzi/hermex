# 0166. Session split view

Area: ui-theming

## Hide the plain List background in a split sidebar

A split view's sidebar paints gray behind a plain List, and only its rows cover it. `BotsInboxView` and `HermesSessionListView` set `.scrollContentBackground(.hidden)` and paint the app canvas (`Color(.appCanvas)`) themselves.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`, `HermesMobile/Features/SessionList/HermesSessionListView.swift`

## Track a user-collapsed sidebar apart from columnVisibility

`SessionSplitView` tracks whether the user collapsed the sidebar apart from `columnVisibility`, because the system also writes `.detailOnly` there for a sidebar that `.automatic` hid, which isn't a collapse. `NavigationSplitViewVisibility.isCollapsedByUser(after:was:)` counts only a move from a showing sidebar to `.detailOnly`, since the system only hides a sidebar that's out when the user asks it to.

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Pop the detail column's UINavigationController on root selection

The split view adopts the detail `NavigationStack` into a `UINavigationController` that outlives the stack's identity: re-identifying the stack rebuilds the root but leaves screens the old root pushed (Settings subpages, workspace files, forks) on top. `DetailColumnNavigation` holds that controller, and `popToRoot()` pops the old root's screens as a root selection lands, before the new root appears, so the new root starts on an empty stack and can push right away (#116).

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`
