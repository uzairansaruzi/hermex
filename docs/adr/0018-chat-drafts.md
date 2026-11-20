# 0018. Chat drafts

Area: chat-composer

## Key Hermes drafts by lineage root and working folder

`HermesConversation` gives the composer draft its key, which its attachments share. A Bot Chat keeps the key it has always had, so no saved draft moves. A session in a legacy compression chain keys by the chain's `lineageRoot` when its row or link named one, so every segment's chat shares the list row's draft (#1176). A new session keys by its working folder, so New Session in each project keeps its own draft (#1683).

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`

## Move a new session's draft only after its first accepted prompt

The host's first accepted prompt moves a new session's draft to the session's key. Before that the draft keeps the new-session key: the host keeps no row for a session with no prompt and reaps it, and nothing reopens it, so a draft typed before leaving waits for the next New Session.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Keep durable app-owned copies of draft attachments

`ChatDraftAttachmentStore` keeps durable, app-owned copies of staged composer attachments, and a draft record references one by file name. The server scopes uploads per session and deletes them with the session, so the copy lets the attachment be re-uploaded after the app's process or the server-side upload inbox is gone.

Lives in: `HermesMobile/Persistence/ChatDraftAttachmentStore.swift`

## Treat unreadable draft attachments as transient

`ChatDraftAttachmentStore` reports why a durable copy could not be read, and therefore whether its record is worth keeping. Collapsing every read failure to "gone" would report a copy that is merely unreadable right now, such as under data protection before first unlock or after a transient I/O error, as permanently lost; it would be dropped from the draft and its file later reclaimed by the sweep. Such a copy is retried instead.

Lives in: `HermesMobile/Persistence/ChatDraftAttachmentStore.swift`, `HermesMobileTests/ChatDraftAttachmentStoreTests.swift`

## Persist submission uncertainty before sending

`ChatDraftStore` writes the submission record durably before a Bot Chat or Hermes session submission, so the loss of an acknowledgement survives relaunch (#508).

Lives in: `HermesMobile/Persistence/ChatDraftStore.swift`

## Delete only attachments a send carried

A send carries exactly the attachments staged in the composer at the moment it is submitted. `ChatDraftStore` keeps every other record in the draft, such as one still waiting on a re-upload retry or one a restore pass has not reached yet, along with its durable copy. Getting this wrong deletes files for attachments the user never sent.

Lives in: `HermesMobile/Persistence/ChatDraftStore.swift`

## Skip queue parking for sessions deleted this launch

On iPad a chat stays on screen while its session is deleted from the sidebar, so it parks its queue after the discard. `ChatDraftStore` remembers the sessions deleted in this launch so that parking does not bring back a draft nobody can open.

Lives in: `HermesMobile/Persistence/ChatDraftStore.swift`

## Lock draft storage while reading a draft

The attachment cleanup in `ChatDraftStore` writes a tentative removal to disk and repairs it if a composer opens, edits or moves a draft while the write suspends. `ChatDraftStore.draft(for:)` takes the storage lock so hydration never captures a reference from such a tentative cleanup write.

Lives in: `HermesMobile/Persistence/ChatDraftStore.swift`

## Rewrite authoritative drafts after a failed write

An atomic write may have succeeded before a protection-attribute failure. When the tentative cleanup write throws, `ChatDraftStore` writes the authoritative `drafts` back before propagating the error.

Lives in: `HermesMobile/Persistence/ChatDraftStore.swift`

## Write the transfer copy before removing the source draft

Move to Hermes's draft step (#1214) moves `source`'s unsent text, quotes and attachment records to `destination` without overwriting either side. Settings stay behind: they name the old server's models and folders, and an existing session never restores them. The copy is on disk before the source goes, so a quit between the two leaves the same draft in both places, which the next call finishes as `.alreadyMoved`. A destination holding a different draft is `.conflict` and both stay untouched; a failed save puts back what the call changed and throws, so neither draft is lost. Attachment files stay where they are; only their records move.

Lives in: `HermesMobile/Persistence/ChatDraftStore.swift`
