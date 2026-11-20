# 0132. Session home and navigation

Area: sessions

## Key the logged-in tree on the active server

Switching the active server keeps `ContentView` in `.loggedIn`, so without a per-server identity SwiftUI reuses the same `SessionListView` and its server-bound view model, leaving the previous server's sessions and chat on screen. The logged-in subtree is keyed on the active server, which tears the whole stack down and rebuilds it against the newly active server (#17).

Lives in: `HermesMobile/ContentView.swift`

## Keep Hermes Settings a sheet across width changes

A signed-in Hermes server's home (#899, #709) is a sidebar and detail at regular width, or one navigation stack where compact-width chats push, on either side of the Sessions/Bots switch; each side leads with the session list's header and takes the home's bar (`HermesHomeChrome`). The home keeps both sides' state, open chat included, so a switch or a size-class change shows the last roster, rows or chat at once while they refresh. It opens on the side last shown (Sessions at first); a Bot link (a push tap, a search hit) turns it to Bots, and a session link (#1176), a Shortcut's new session (#1180), a share (#1181) or a Limits widget's Usage link (#1409) turns it to Sessions. Settings opens as a sheet beside a split and pushes at compact width, but a sheet stays a sheet when the width changes: pushing it above an open chat (a fold) would clear both.

Lives in: `HermesMobile/ContentView.swift`

## Attach the Hermes Settings sheet outside the home branches

The Settings sheet modifier sits outside the Sessions and Bots branches of the Hermes home, so the sheet outlives the switch between them. Attached inside a branch, switching sides would dismiss it.

Lives in: `HermesMobile/ContentView.swift`

## Keep Plus/Max landscape on the stack, not a split

A home owns a split only at regular width with room to stand in; pushed lists keep their caller's stack. A Plus/Max iPhone in landscape is regular width but compact height, and stays on its stack: a split there would rebuild the open chat in the middle of every rotation (#1528).

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Reopen a named New Session by its key on rebuild

When the home rebuilds a chat view (a size-class change, a side switch), a New Session the host has already named reopens by its key, so the rebuild shows that session instead of starting another, and New Chat with Voice doesn't dictate again. A live chat's view keeps its model.

Lives in: `HermesMobile/Features/SessionList/HermesSessionListView.swift`

## Keep the list live regardless of SwiftUI appear/disappear order

When the list's rows leave a phone's screen, a chat over them pauses the list's events and keeps its socket; anything else closes the list. View all shows the same rows and opens the list as it appears, and when View all leaves the screen, a chat it opened (or anything else covering it while still pushed) pauses the events, while popping back to the list, which opens them as it appears, keeps them live. This holds whichever of the two SwiftUI runs first; on the simulator View all's appearance comes first.

Lives in: `HermesMobile/Features/SessionList/HermesSessionListView.swift`

## Scroll the home list to its header before focusing search

Each search request scrolls the home's list back to its header first, because a scrolled list has recycled the header and its search field. This lets the iPhone Duo rail's Search and ⌘F work from any row, even with search already open.

Lives in: `HermesMobile/Features/SessionList/HermesSessionListView.swift`

## Pop compact navigation to the list before opening Notifications

A chat's one-time notifications offer (#863) opens Settings → Notifications. On compact width a fork or a chat under Settings → Archived Sessions can sit above the destination, and retargeting the destination leaves it on top, so compact pops to the list first and the list opens Notifications once it is back on screen. Regular width already pops the detail column on every root selection.

Lives in: `HermesMobile/Features/SessionList/SessionListView.swift`

## Attach refreshable to the session List, not the navigation container

`.refreshable` sits on the session `List` itself. A refresh action set higher up is inherited by every `ScrollView` in pushed chats, which made the composer's attachment strip pullable.

Lives in: `HermesMobile/Features/SessionList/SessionListView.swift`
