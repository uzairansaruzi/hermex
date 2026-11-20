# 0103. Bot face motion

Area: performance

## Stop the working face's 15 fps loop after one beat

`BotFaceMotion` has three modes: `.still` is one frozen frame, used by the picker tiles, Reduce Motion and the extensions; `.idle` blinks on a sparse schedule; `.working` is Desktop's lean-and-sway pose for the open bot while its turn is live. `BotWorkingSchedule` runs 15 fps for `beat` seconds from `start`, then only the bot's blink edges, holding a still lean, so a two-hour run stops repainting after the beat and a long turn never keeps a 15 fps loop running. `start` is when the current beat began: the turn started working, or the app came back to the foreground mid-turn. `BotWorkingBeat` starts a beat only when the turn enters work after being seen not working (a new prompt, an answered approval) or after the chat opened or came back to the foreground; a same-turn reconnect passes through `.unknown`, and that and an arriving approval never start one, so a long turn settles. A waiting face never uses the schedule (#757).

Lives in: `HermesMobile/Features/Bots/BotFaceMotion.swift`

## Run the sway beat only for a working bot

`BotTitleFace.motion` returns the working sway (from `beatStart`) only for work; every other face just blinks, so a pending approval never runs the 15 fps beat.

Lives in: `HermesMobile/Features/Bots/BotProfileAppearance.swift`

## Repaint bot faces only at blink edges

`BotBlinkSchedule` is a `TimelineView` schedule that fires only at blink edges: shut, then open 180 ms later, every 3 to 5 seconds. Nothing repaints between entries. The period and phase are seeded by the bot's name so a list of faces never blinks in unison.

Lives in: `HermesMobile/Features/Bots/BotFaceMotion.swift`

## Key the idle-bit task on Reduce Motion

`BotInteractiveFaceView` keys its idle-bit `.task(id:)` on Reduce Motion as well as the bot, so flipping Reduce Motion restarts, or stops, the idle loop.

Lives in: `HermesMobile/Features/Bots/BotFaceMotion.swift`

## Write inbox live statuses only on a real change

`BotInbox.setLiveStatuses` writes only a real change, so an unchanged re-read never invalidates the list.

Lives in: `HermesMobile/Features/Bots/BotInbox.swift`
