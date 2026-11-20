# 0007. Bot connection sign-in and lifecycle

Area: bots

## Offer Update sign-in instead of Reconnect after a rejected password

After the host refuses the saved username or password (`.rejected(401)`), reconnecting would only send the refused password again (#884). So bot rooms, room profiles, chats and the inbox show Update sign-in in Reconnect's slot (`BotComposerPill.updateSignIn`, `BotRoomProfileView`, `BotsInboxView` when `inbox.needsSignIn`), and the button opens the sign-in form. `BotRoomReader.needsSignIn` is set on the 401 and stays set for the reader's life, because the reader only signs in with the record it was built from; the fix goes through the inbox, which opens the room with a new reader. Once the host has refused this reader's password, `BotRoomReader.open` only restores the saved history and stops.

Lives in: `HermesMobile/Features/Bots/BotRoomComposerView.swift`, `HermesMobile/Features/Bots/BotRoomProfileView.swift`, `HermesMobile/Features/Bots/BotRoomReader.swift`, `HermesMobile/Features/Bots/BotsInboxView.swift`

## Never resend a refused password until the saved sign-in changes

Foregrounding, pull to refresh, and closing the connection form unsaved all rerun `BotInbox.open()`, and none of them may spend another of the host's password logins (#884). The refused password goes out again only when the saved sign-in changes. A chat or room that saw the 401 returns to the inbox's sign-in form, because its client is bound to the rejected sign-in, and the inbox reloads the record when the form closes. Its callback calls `noteRejectedSignIn` before it pops, so the inbox's reappearing `open()` sends nothing, including when the 401 came while the inbox was off screen; a rejection recorded for another connection record is ignored.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`, `HermesMobile/Features/Bots/BotsInboxView.swift`, `HermesMobileTests/BotInboxTests.swift`

## Retry a saved sign-in even when unchanged

Saving the connection form retries sign-in even when the record is unchanged, because the host itself may have caused the earlier refusal (Decision D3 on #884). This is the one exception to never resending a refused password.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`, `HermesMobileTests/BotInboxTests.swift`

## Check needsSignIn before making a room wire

`BotRoomReader.open` checks `needsSignIn` before it calls `makeWire`, because `makeWire` can retire a newer shared connection. A reader that must not sign in again must not disturb the connection another screen now uses.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Offer a new address instead of Reconnect on a wrong listener

When `inbox.needsAddress`, reconnecting reaches the same listener (#1598), so `BotsInboxView` offers no Reconnect. A Hermes server's address is fixed, so its way out is Add Server, another server; a webui's Bot connection edits its own address in the Hermes connection form.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`

## Refuse sign-in when the status read is not the dashboard's

Before the password goes out, `BotClient.connect` requires the public `/api/status` read to be answered by the Hermes dashboard itself. An access proxy such as Cloudflare Access may redirect the read to its own sign-in page on another host, or refuse it with its own non-JSON 401 page; both fail as `BotFailure.blocked`, not "not a dashboard", and no password is sent. Only a JSON 401, the webui's auth gate, reads as `BotFailure.notDashboard`.

Lives in: `HermesMobile/Networking/Bots/BotClient.swift`, `HermesMobileTests/BotClientTests.swift`

## Keep bot connections through the inactive scene phase

Control Center and notification banners move the scene to `.inactive` (#902). The Bots inbox, a bot room, its profile screen and the bot profile editor keep their connection through that; only `.background` closes it (#533), and a room left on background keeps its loaded history. On return to active, only a connection the background stopped (link idle) reopens or reloads, exactly once.

Lives in: `HermesMobile/Features/Bots/BotsInboxView.swift`, `HermesMobile/Features/Bots/BotRoomView.swift`, `HermesMobile/Features/Bots/BotRoomProfileView.swift`, `HermesMobile/Features/Bots/BotProfileEditor.swift`, `HermesMobileTests/BotInboxTests.swift`, `HermesMobileTests/BotProfileEditorTests.swift`
