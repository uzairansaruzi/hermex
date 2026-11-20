# 0008. Bot creation and Profile editing

Area: bots

## Lock create-sheet fields once the Profile write is dispatched

Once `BotCreator` has dispatched the Profile write, the name and look are on the host and a retry only finishes the remaining steps. `BotCreateView` stops them being edited, since editing them there would be a lie; the bot is edited afterwards instead.

Lives in: `HermesMobile/Features/Bots/BotCreateView.swift`

## Send no_skills only for new bots, never with clone_from

`BotCreator.Draft` sends `no_skills` for new bots only, so the host seeds only its essential skills. The host refuses it with `clone_from`, since a copy brings the source's skills.

Lives in: `HermesMobile/Features/Bots/BotCreator.swift`

## Use the generation counter, not wire, to decide create ownership

A disconnect clears `wire` before the suspended call in `BotCreator.create` throws. So only the generation decides whether this attempt still owns the sheet.

Lives in: `HermesMobile/Features/Bots/BotCreator.swift`

## Adopt an existing Bot Chat before minting one

`BotCreator.ensureChat` is adopt-before-mint, as Desktop is: an existing "Bot Chat" row is the bot's chat and is never duplicated. Only a confirmed absence from `findChat` creates one.

Lives in: `HermesMobile/Features/Bots/BotCreator.swift`

## Read the real look revision before saving a Profile

A bot chat's pill opens `BotProfileEditor` with a bare roster row until its roster read answers. Saving that row would claim revision 0 and read as a change made elsewhere, so `BotProfileEditor.load` reads the real revision first.

Lives in: `HermesMobile/Features/Bots/BotProfileEditor.swift`
