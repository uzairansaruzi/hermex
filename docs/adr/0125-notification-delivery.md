# 0125. Notification delivery and taps

Area: push

## Set the notification delegate during launch

`PushAppDelegate` sets `UNUserNotificationCenter.current().delegate` inside `didFinishLaunchingWithOptions`. Set any later, the tap that cold-started the app is lost.

Lives in: `HermesMobile/Push/PushAppDelegate.swift`

## Route bot push taps by pairing, not Profile name

`PushNotificationRouter.botDestination` picks the server from the push's pairing, so a tap can never land on a bot with the same Profile name under another server. It returns nil, and the app simply opens, for a webui or other source, a preview that never opened (the Profile lives inside it), a pairing since wiped, or a server with no Bot connection. One host reached through two configured servers (LAN and a tunnel) hands both the same install key, so the tap stays on `activeServer` when it is one of them and otherwise takes the first by URL that has a Bot connection. The destination carries no conversation: the payload's `session_id` is the run's live session, not the bot's durable root, and a bot has one chat; a Hermes server's push opens its session instead.

Lives in: `HermesMobile/Push/PushNotificationRouter.swift`

## Let only the entering screen clear push presence

Presence records which conversation is on screen so its banners can be suppressed, keyed by the owner that called `enter`. `leave(owner:)` clears it only for that owner, so an old chat disappearing after its replacement appeared, even one for the same conversation, leaves the new one on record.

Lives in: `HermesMobile/Push/PushNotificationRouter.swift`

## Deliver notification service content exactly once under a lock

In `HermesNotificationService`, the system calls `serviceExtensionTimeWillExpire` on its own thread while `didReceive` may still be working, and the content handler must run exactly once. `deliver` takes and clears `contentHandler` under a lock, so whoever gets there first wins.

Lives in: `HermesNotificationService/NotificationService.swift`

## Keep shared push preview code to Foundation, CryptoKit and Security

`PushPreview.swift` is shared by the app and `HermesNotificationService`, and the extension links no networking, no SwiftData, and no third-party package, so nothing in that file may reach for one. `PushPreviewKeys.stored` reads every pairing in the shared push access group with Security directly, so the extension does not link KeychainAccess; the items are the generic passwords `KeychainPushPairingStore` writes, and anything unreadable is skipped.

Lives in: `HermesMobile/Push/PushPreview.swift`

## Guard relay Live Activity loc-keys in the String Catalog

The hermex-push relay sends "Response complete" and "Response failed" as the `loc-key` of a Live Activity's end alert (#888), and iOS resolves them from the String Catalog. A rename or cleanup there has no compile error to catch it and the alert would silently fall back to the English key, so `LocalizationCatalogTests` checks the keys are localized in every shipped language.

Lives in: `HermesMobileTests/LocalizationCatalogTests.swift`
