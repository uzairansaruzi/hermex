# 0012. Bot room messaging

Area: bots

## Never annotate room sends with bot identification

In `BotRoomMentions`, room handles are server routing keys; friendly names only help searching. Unlike a bot's chat, a room send must never append an identification annotation.

Lives in: `HermesMobile/Features/Bots/BotRoomComposerView.swift`

## Hold the confirmed room action separately from the card

The room action card keeps the action whose Discard is being confirmed in its own `confirmingDiscard` state, apart from `action`. Room cards are keyed by position, so a poll can hand the card another task while the confirmation sheet is open, and confirming must still act on the task the user saw.

Lives in: `HermesMobile/Features/Bots/BotRoomComposerView.swift`

## Let each visible room screen claim socket ownership

A room and its profile screen share one `BotRoomReader`, but each visible screen claims async ownership through the owner token `BotRoomReader.open` takes. Navigation callbacks can arrive in either order, and the old screen must not close the new screen's socket.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Never resend room commands automatically

`BotRoomReader.send` starts a new thread from the overview and continues the current discussion from detail; only the dedicated retry button reuses an uncertain send's event id and payload. `BotRoomReader.command` checks ownership and the pending tuple inside `BotClient`'s actual socket write closure, and a lost reply never starts another command. A dispatched command with no reply stays in `uncertainSends`, and a rejected retry does not erase the uncertainty of the original send.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Poll a room after every command reply

`BotRoomReader.command` reads room state after every acknowledgment or rejection, including codes 5118 and 5119. Action tuples marked inactive stay inert even if a stale server snapshot repeats them.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`

## Hide pending room sends until acknowledged

A poll can race the send acknowledgment, so `BotRoomReader.publishLog` filters out the user's own `message.user` events whose event id matches a pending or uncertain send; a message must not show as sent before the RPC result is validated. `BotRoomReader.saveRecentTranscript` likewise does not save while a command is busy or a disband is uncertain, so pending send bubbles stay private until their acknowledgment is known.

Lives in: `HermesMobile/Features/Bots/BotRoomReader.swift`
