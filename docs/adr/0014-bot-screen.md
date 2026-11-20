# 0014. Bot Screen

Area: bots

## Route the Screen shortcut through a shared registry

For ⌘⇧S's Screen (#1633), the chat on screen offers its card's opener to `ScreenShortcut.shared`, and `HermexCommands` reads it ahead of the scene's actions. It is a shared registry rather than a focused or environment value, because a session pushed from a chat, from Archived or from Settings is a `navigationDestination` no list's value reliably reaches. A Bot Chat offers the same Screen the Bots home's own action would.

Lives in: `HermesMobile/Features/Bots/BotScreenCard.swift`

## Reapply Screen focus when the canvas joins a window

`ScreenCanvasView.applyFocus` runs again when the view joins a window, because only a view in a window can become first responder.

Lives in: `HermesMobile/Features/Screen/ScreenCanvas.swift`

## Keep the Screen key field empty

`ScreenKeyField` carries the iOS keyboard: Paste and password AutoFill insert through it, and each scalar goes out as a key. It stays empty, so nothing typed, a password least of all, is kept on the phone.

Lives in: `HermesMobile/Features/Screen/ScreenCanvas.swift`

## Save a Screen hold in the Keychain before acquiring

`ScreenHold`, a takeover this iPhone made and hasn't handed back, is saved before the acquire goes out, because a phone that suspends before the reply could otherwise hold a lease with no record of its id. So `viewerIDs` names every id that may hold it: one once things settle, two while a return moves it to a new socket's id. Each id is a capability on the host, so the hold lives in the Keychain. `lastInput` is saved when the app leaves the foreground and at takeover, so a killed app's deadline errs early.

Lives in: `HermesMobile/Features/Screen/ScreenControl.swift`

## Forget a Screen hold only if it still names the same viewer ids

`ScreenHoldStore.forget` forgets the saved hold only if it still names the given `viewerIDs`. A reply about an old hold must not erase one retaken since by a quick switch away and back.

Lives in: `HermesMobile/Features/Screen/ScreenControl.swift`

## Enforce the Screen idle limit in the app on Linux hosts

`ScreenIdlePolicy` (prompt at 14 min, limit at 15 min) is how long a takeover lasts with no phone input. The hermex-screen plugin enforces it on the host for Mac and Windows, but a stock host's leases never expire, so on Linux the app enforces it when it next runs.

Lives in: `HermesMobile/Features/Screen/ScreenControl.swift`

## Hand back Screen holds on their own connection

`ScreenHolds` hands back holds from outside a Screen view: Bots home's banner, the Bot Screen switch, a server switch or sign-out, and a takeover that expired while the app was away. Each runs on a connection of its own, so replacing the server's shared connection can't cut it off, and each waits at most 4 s so sign-out never hangs.

Lives in: `HermesMobile/Features/Screen/ScreenControl.swift`

## Show the host's Screen blocker before missing packages

`ScreenStatus.settledPhase` checks `blocker` before `installed`. A sandbox missing its desktop image reports that as well as the missing packages, and installing packages on the host wouldn't fix it.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`
