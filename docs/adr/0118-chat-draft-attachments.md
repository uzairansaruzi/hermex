# 0118. Chat draft attachments

Area: persistence-cache

## Reconcile a send against the staged attachments only

`ChatView.sendStandardMessage` computes `ChatDraftSendReconciliation.outcome` from the composer's actually staged attachment IDs, not the draft's whole record set (`lastSyncedDraftAttachments`). A record that is not staged, because it awaits a re-upload retry or an in-flight restore has not reached it yet, was never carried by this send, so its durable copy must survive; it stays in `draftAttachmentsPendingRetry`.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Restore draft attachments from the app-owned copy, never the server path

`ChatView.restoreDraftAttachments` rebuilds the composer's staged attachments by re-uploading each record's durable local copy against this session; a Hermes session only stages it again and its send uploads it. The persisted server path is never trusted, because uploads live in a per-session inbox the server deletes with the session. Records whose copy is missing are dropped with a notice, records whose re-upload fails stay in the draft and retry on a later open, and the rest of the draft loads either way.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Keep untried attachments when a draft restore is cancelled

Leaving the chat mid-restore is not a restore failure. When `ChatView.restoreDraftAttachments` is cancelled, every record from that point on is untried, so the whole remainder goes into the retry set. The draft-attachment sync after the restore is authoritative: anything missing from it would be dropped from the draft and later swept from disk.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`
