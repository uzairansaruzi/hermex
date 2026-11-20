# 0003. Bot avatars

Area: bots

## Generate bot avatars through prompt.btw

`BotAvatarGeneration` ("Describe It") draws one avatar from the host's model through `prompt.btw`, which denies every tool at dispatch. A real turn is not safe here: `prompt.submit` runs terminal and file tools with no approval request, a dropped socket does not stop it, and `session.resume` can auto-continue it.

Lives in: `HermesMobile/Features/Bots/BotAvatarGeneration.swift`

## Run avatar model calls in their own serialized task

Each call is one tool-free model call in a hidden draft session under the Profile, and `BotAvatarGeneration` runs it in its own task: cancelling a call that isn't cancellation-safe ends the screen's whole connection, so stopping only stops the waiting. One call runs at a time, because a call nobody is waiting for may still hold the shared socket's handlers until its reply lands, even after its sheet has closed. The draft is closed and its empty stored row deleted afterwards even when the caller stopped waiting, unless the socket itself has gone, and a call reads the shared socket's events for its own task only.

Lives in: `HermesMobile/Features/Bots/BotAvatarGeneration.swift`

## Retry deleting a draft session the host is still closing

The host refuses to delete a session it is still closing. So after `session.close`, `BotAvatarGeneration` tries `session.delete` of the draft up to `deleteAttempts` (4) times, `deleteRetryDelay` (2 s) apart.

Lives in: `HermesMobile/Features/Bots/BotAvatarGeneration.swift`

## Keep btw answers that arrive before the task id

`prompt.btw` can answer before its own reply, which carries the task id, is read. `AnswerWaiter.receive` therefore keeps an early `btw.complete` answer instead of dropping it.

Lives in: `HermesMobile/Features/Bots/BotAvatarGeneration.swift`

## Store generated avatars under a Hermex-owned ui_meta key

`BotGeneratedAvatar` (one path, its eyes and a short name the host's model drew from a description) is stored inline under the Hermex-owned key `hermexAvatar` in `ui_meta["hermes-bots"]`, the way `expression` is. Desktop and older Hermex builds ignore the key and keep drawing the stored `shape`.

Lives in: `HermesMobile/Features/Bots/BotGeneratedAvatar.swift`

## Detect host failure copy before parsing avatar JSON

A failed call comes back as ordinary text, and its provider detail can hold JSON of its own. `BotGeneratedAvatar.read` checks the reply for the host's failure markers (`hostFailureMarkers`: "Provider said:" and "Details:") before extracting JSON, so that detail is never parsed as an avatar.

Lives in: `HermesMobile/Features/Bots/BotGeneratedAvatar.swift`

## Preserve unknown Profile look fields on save

`BotProfileAppearance` keeps the generated-avatar value exactly as the host stored it until the user picks a face, and a save writes it back as it was. A newer build's fields, or a format this build can't read, are never lost.

Lives in: `HermesMobile/Features/Bots/BotProfileAppearance.swift`

## Seed default bot faces only from classic shapes

`BotAvatarShape.classic` lists the original shapes, and name-seeded faces pick only from these. Adding an avatar shape then never changes a bot that nobody customized.

Lives in: `HermesMobile/Features/Bots/BotProfileAppearance.swift`

## Keep the look revision when the editor replaces an avatar

`BotAvatarStore.setImage` applies an acknowledged editor write immediately and keeps the current look revision on purpose. Replacing only the asset does not advance the UI metadata, so a later roster refresh must retain the new thumbnail.

Lives in: `HermesMobile/Features/Bots/BotAvatarStore.swift`

## Treat Desktop's 160x160 PNG as a face copy

`BotAvatarStore` reads a `profiles.get_asset` reply, and anything other than a found base64 image data URL within the size cap (`maxPayloadBytes`) is nil, so a later fetch retries it. Unless the look says `photo`, a 160x160 PNG is `faceCopy` (`isBackfilledFacePng`): Desktop uploads a still copy of its own drawing at that size for any bot without an asset and draws the face over it the same way.

Lives in: `HermesMobile/Features/Bots/BotAvatarStore.swift`

## Refresh one bot's avatar after an appearance conflict

`BotProfileEditor.reloadAppearance` fetches only this Profile's asset. A roster-wide refresh would drop every other bot's image.

Lives in: `HermesMobile/Features/Bots/BotProfileEditor.swift`

## Forget the widget's avatar copy when the photo is removed

Removing a bot's avatar does not change its look revision, so the Bot widget's copy would still read as current. `BotProfileEditor` deletes it with `BotWidgetPublisher.shared.forgetAvatar` (#1643).

Lives in: `HermesMobile/Features/Bots/BotProfileEditor.swift`
