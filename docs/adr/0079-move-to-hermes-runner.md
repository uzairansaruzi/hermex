# 0079. Move to Hermes runner and sheet

Area: move-to-hermes

## Give a Move its own Hermes connection

`MoveToHermesDestination` builds its client on a connection of the Move's own, never the shared one: `HermesConnections.shared` keeps one connection, and asking it for the destination would close the active server's. `connections` makes the Move's connection beside the shared one (`ownConnection`), so a browser sign-in's rotated refresh tokens are saved as the destination's own connection saves them (#1265).

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesRunner.swift`

## Move drafts one chat at a time, logging each result

`MoveToHermesRunner.moveDrafts` moves one chat's draft at a time and logs each result before the next. A quit then loses at most one chat's result: its draft has already moved, and Resume finds nothing left to move for it.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesRunner.swift`

## Recheck the move record just before each draft transfer

`MoveToHermesReconcile.moveDrafts` asks `canTransfer` again just before each transfer, and the runner's check rereads the move record. Removing the destination server discards its drafts before its entry goes, so a draft moved after that point would be lost with them.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesRunner.swift`, `HermesMobile/Features/MoveToHermes/MoveToHermesReconcile.swift`

## Run the webui server removal outside the sheet's lifetime

`MoveToHermesSheet.removeSource` is Remove's confirmation: it switches to the destination as Done does, then removes the webui server. It starts the removal in an unstructured `Task` and then dismisses, because the switch may tear the sheet down and the removal must outlive it.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesView.swift`

## Count on-screen chat lists instead of storing a flag

`MoveToHermesNotices.chatListsOnScreen` counts, per server, how many of its chat lists are on screen. A webui list reports its appearance through `noteChatList`: on iPhone it disappears under a pushed chat, on iPad with its sidebar. A rebuild's new list can appear before the old one leaves, so a Bool would hide a list that is still on screen; the count keeps `showsChatList` true.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesModel.swift`
