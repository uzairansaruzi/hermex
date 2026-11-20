# 0162. Home bar, vertical rail, and adaptive layout

Area: ui-theming

## Hide the bottom scroll edge effect under the Hermes home bar

`HermesHomeChrome` gives both sides of the Hermes home the same bar chrome (#709): no top bar, since each side's list leads with `SessionsHeader`, and a bottom bar of `(filter) [Bots | Sessions] (new chat)` whose ends each side fills. The title names a pushed screen's back button and stays inline so a pushed screen such as Tasks keeps the one-line bar. On iOS 26 the bar's glass pills float over the list, and the system's bottom scroll edge effect read as a solid band behind them, so `HiddenBottomScrollEdge` hides it. Where the system draws a vertical bar (iPhone Duo), the bar's buttons and the header's search and avatar move into it (`HermesHomeRailItems`) and the header drops its pill (`homeBarOwnsSearch`); unfolded, the rail belongs to the split's detail column, so the detail carries them (`HermesHomeDetailBar`) and the sidebar shows no bar.

Lives in: `HermesMobile/Features/Hermes/HermesHome.swift`

## Give the rail home no navigation title

With the vertical rail the navigation bar stays visible, and returning from a pushed screen drew the title for a moment before its removal landed. So the rail's home has no title.

Lives in: `HermesMobile/Features/Hermes/HermesHome.swift`

## Keep a seen vertical bar until the size class changes

`VerticalBarReader` (iOS 27.1, iPhone Duo) reports whether the system draws a vertical bar. In a split the bar is the detail column's: the sidebar reads it too, but its bars stay horizontal. The system reports no bar while a pushed screen covers the reader, a swipe back included, which redrew the screen underneath without its rail until the swipe landed. So a bar once seen stays until the size class changes, as a fold does.

Lives in: `HermesMobile/Features/Hermes/HermesHome.swift`

## Pin the rail home's list 24 pt below the top

The rail's home has no top bar, but a swipe back lends it the pushed screen's bar until the swipe lands, which dropped the list by a row and then jumped it back. With the rail, `RailTopInset` makes the list ignore the bar and keep the 24 points an empty bar leaves above it.

Lives in: `HermesMobile/Features/Hermes/HermesHome.swift`

## Give the home switch a 200 pt minimum width

`HermesHomeSwitch`'s `[Bots | Sessions]` picker uses a 200 pt minimum width with `.fixedSize()`. A bare `.fixedSize()` hugs the longer label (#1344); the minimum gives both segments room, and a longer translation still widens the switch instead of truncating.

Lives in: `HermesMobile/Features/Hermes/HermesHome.swift`

## Give the vertical toolbar bar one item per chat action

Where the system draws a vertical bar (iPhone Duo, iOS 27.1+), `ChatView.chatActionRailItems` emits each trailing action as its own toolbar item, since the bar can't hold the trailing cluster's custom view. Custom labels must prefer the vertical bar explicitly, or they fall back to a horizontal one.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Draw the welcome glow as a background

`OnboardingWelcomePage` draws its glow in a `.background`, which takes no layout. On a short display (iPhone Duo folded) the glow's overflow goes to the copy instead of scrolling the copy behind the buttons.

Lives in: `HermesMobile/Features/Onboarding/OnboardingWelcomePage.swift`

## Keep the Screen picture's identity across rotation

`ScreenView.live` puts the picture's controls under it in portrait and, in landscape with the trackpad on, in a side panel taking a third of the width. It switches layouts through `AnyLayout` so the picture keeps its place in both, and a rotation keeps its zoom and keyboard focus.

Lives in: `HermesMobile/Features/Screen/ScreenView.swift`
