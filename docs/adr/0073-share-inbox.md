# 0073. Share inbox and extension

Area: live-activity-share-intents

## Stage shortcut text in the share inbox, not the deep link

`AppIntentRouter.openNewChat(prefilling:server:profile:origin:)` opens a new chat with the text in the composer for review; nothing is sent (#1402). The text and its destination wait in the app group's share inbox first (`HermesShareDraft.saveShortcutText`), so a cold launch, a server switch or a sign-in can't lose them, and only the bare share link travels as the deep link. Each call is its own chat text, even for the same text. The Hermes home adds it to that Profile's new-session draft after any unsent text and opens it with a review notice naming `origin`; callers are the New Chat with Content intent and About's Troubleshoot with Hermes (#1476).

Lives in: `HermesMobile/AppIntents/HermexAppIntents.swift`

## Store a server digest, not its URL, in queued records

`SharedShortcutDestination.serverKey` is a digest of the server's URL, so the queued app-group record holds no server URL (#1509). The app matches it against the servers it has configured, so a removed server can't be named.

Lives in: `HermesMobile/Features/Share/SharedDraftStore.swift`

## Identify a share occurrence by item ID and creation time

`SharedImportReservation.occurrenceID` identifies one share (#1197): stable across retries, releases and relaunch replays of one queued item, but new when the same content is shared again after it was consumed, whose `itemID` (a content hash) repeats. `ChatDraft.sharedImportIDs` records the occurrence IDs already moved into a draft, so a retried or replayed share isn't added twice (#1181, #1197). The set rides along with the content and never keeps a draft alive on its own.

Lives in: `HermesMobile/Features/Share/SharedDraftStore.swift`, `HermesMobile/Persistence/ChatDraftStore.swift`

## Tolerate another process taking a share inbox item

The share extension and the app touch the app-group inbox concurrently. In `HermesShareDraft`, a failed move while reserving an item is skipped when the pending file is gone, since another process reserved or consumed it after enumeration. A failed move while enqueueing counts as success when the item already exists, since a concurrent extension save of the same content is a successful deduplication.

Lives in: `HermesMobile/Features/Share/SharedDraftStore.swift`

## Drop malformed share records so they never block the inbox

`HermesShareDraft` deletes a malformed, incomplete or expired inbox record instead of throwing, so it can't block later valid shares. A malformed legacy single-slot payload is dropped too: the legacy format has no partial recovery path, and keeping it would permanently block valid records in the transactional inbox.

Lives in: `HermesMobile/Features/Share/SharedDraftStore.swift`

## Commit a share to disk before releasing it

`ChatDraftStore.appendShare` adds a share to a draft (#1181): text after any unsent text and files after any staged ones, so an earlier share waiting there is kept. Each file gets its durable copy first; the records, text and share ID then land in one change that is on disk before this returns, so the caller can let go of the share. A share already there (a retry, or a replay after the app quit before letting go) adds nothing. `fits` vets the records in the same step that adds them, and any throw (cancellation, storage, a limit, a record or the text dropped meanwhile) takes back only what this share added, on disk before its copies go, so the share can be moved again. Text with an `origin` (#1402, #1476) leaves the unsent text as it is and turns on the draft's review notice.

Lives in: `HermesMobile/Persistence/ChatDraftStore.swift`

## Map shared attachment bytes instead of loading them

`ShareInputReader` maps a shared file's bytes (`mappedAttachmentData(at:)`) instead of copying them into the extension's memory, and returns nil when the file exceeds `HermesShareDraft.maximumSharedAttachmentBytes`. Images and PDFs load through their file representation so an oversized item is rejected by size before any bytes are read (#734). Mapped pages are clean and file-backed, so they are not charged to the extension's footprint, and the mapping stays valid after security-scoped access ends or a provider deletes its temporary copy.

Lives in: `HermesShareExtension/ShareInputReader.swift`

## Map a file representation inside the provider callback

`NSItemProvider.loadFileRepresentation` deletes its temporary file when the completion handler returns, so `ShareInputReader.loadMappedFile` maps the file inside the handler.

Lives in: `HermesShareExtension/ShareInputReader.swift`

## Accept App Review risk to open Hermex from the share extension

Share extensions have no guaranteed containing-app launcher. `ShareViewController` falls back to reaching `UIApplication` through `NSSelectorFromString` and the responder chain on hosts where `NSExtensionContext.open` does not route to the containing app. The maintainer accepted the App Review risk to keep the fast return-to-app experience.

Lives in: `HermesShareExtension/ShareViewController.swift`
